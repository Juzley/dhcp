defmodule Dhcp.Server do
  use GenServer
  require Logger

  alias Dhcp.Binding
  alias Dhcp.Packet

  @udp Application.get_env(:dhcp, :udp_impl, :gen_udp)

  @dhcp_server_port 67
  @dhcp_client_port 68

  @empty_address {0, 0, 0, 0}
  @server_address {192, 168, 0, 1}
  @gateway_address {192, 168, 0, 1}
  @dns_address {192, 168, 0, 1}
  @subnet_mask {255, 255, 255, 0}
  @min_address {192, 168, 0, 1}
  @max_address {192, 168, 0, 255}

  @broadcast_address {255, 255, 255, 255}

  # TODO: Broadcast bit handling
  # TODO: gateway address handling (next server rather than giaddr?)

  # Client API

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, :ok, [name: Dhcp.Server])
  end

  # Server API

  def init(:ok) do
    result = {:ok, %{}}
             |> init_rx_socket()
             |> init_tx_socket()
             |> init_src_mac()
             |> init_binding()

    case result do
      {:error, reason} ->
        {:stop, reason}

      _ ->
        result
    end
  end

  # Initialize the receive socket.
  defp init_rx_socket({:ok, state}) do
    # TODO: Do we need a socket on the unicast addr too?
    case result = @udp.open(@dhcp_server_port,
                            [:binary, {:ifaddr, @broadcast_address}]) do
      {:ok, socket} ->
        {:ok, Map.put(state, :rx_socket, socket)}

      _ ->
        result
    end
  end
  defp init_rx_socket(err), do: err

  # Initialize the send socket.
  defp init_tx_socket({:ok, state}) do
    case result = :packet.socket(0x800) do
      {:ok, socket} ->
        intf = :packet.default_interface()
        ifindex = :packet.ifindex(socket, intf)
        {:ok, Map.merge(state, %{tx_socket: socket, ifindex: ifindex})}

      _ ->
        result
    end
  end
  defp init_tx_socket(err), do: err

  # Get the MAC address for the interface we're going to send on.
  defp init_src_mac({:ok, state}) do
    mac_info =
      :packet.default_interface()
      |> List.first
      |> :inet.ifget([:hwaddr])

    case mac_info do
      {:ok, [hwaddr: mac]} ->
        {:ok, Map.put(state, :src_mac, List.to_tuple(mac))}

      _ ->
        {:error, :if_mac_not_found}
    end
  end
  defp init_src_mac(err), do: err

  # Initialize the binding server.
  defp init_binding({:ok, state}) do
    result = Binding.start(@server_address, @gateway_address,
                           @min_address, @max_address)
    case result do
      {:ok, bindings} ->
        {:ok, Map.put(state, :bindings, bindings)}

      _ ->
        result
    end
  end
  defp init_binding(err), do: err

  # UDP packet callback.
  def handle_info({_, _socket}, state), do: {:noreply, state}
  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    case Packet.parse(data) do
      {:ok, packet} ->
        new_state = handle_packet(state, packet)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.debug "Failed to parse packet: #{reason}"
        {:noreply, state}
    end
  end

  # Handle a successfully parsed DHCP packet.
  defp handle_packet(state, packet) do
    case Map.get(packet.options, 53, :no_type) do
      1 ->
        handle_discover(state, packet)

      3 ->
        handle_request(state, packet)

      7 ->
        handle_release(state, packet)

      :no_type ->
        Logger.debug "Ignoring DHCP message received with no message type"

      msg_type ->
        Logger.debug "Ignoring DHCP message type #{msg_type}"
    end

    state
  end

  # Handle a discovery packet.
  def handle_discover(state, packet) do
    requested_address = Map.get(packet.options, 50)
    offer_info = Binding.get_offer_address(state.bindings,
                                           packet.chaddr,
                                           requested_address)
    case offer_info do
      {:ok, offer_address} ->
        frame_offer(packet, offer_address, state) |> send_response(state)
	end

    state
  end

  # Handle a request packet.
  defp handle_request(state, packet) do
    requested_address = Map.get(packet.options, 50)

    # TODO: Forget the offer if this request isn't for us.
    if packet.siaddr == @server_address do
      result = Binding.allocate_address(state.bindings,
                                        packet.chaddr,
                                        requested_address)
      if result == :ok do
        frame_ack(packet, requested_address, state) |> send_response(state)
      else
        frame_nak(packet, requested_address, state) |> send_response(state)
      end
    end

    state
  end

  # Handle a release packet.
  defp handle_release(state, packet) do
    Binding.release_address(state.bindings,
                            packet.chaddr,
                            packet.ciaddr)
  end

  # Frame a DHCPOFFER
  defp frame_offer(req_packet, offer_addr, state) do
    Packet.frame(
      state.src_mac,
      req_packet.chaddr,
      @server_address,
      offer_addr,
      %Packet{
        op: 2,
        xid: req_packet.xid,
        ciaddr: @empty_address,
        yiaddr: offer_addr,
        siaddr: @server_address,
        giaddr: req_packet.giaddr,
        chaddr: req_packet.chaddr,
        options: %{ 53 => 2,
                    1  => @subnet_mask,
                    3  => [@gateway_address],
                    6  => [@dns_address],
                    51 => 86400,
                    54 => @server_address
        }
      }
    )
  end

  # Frame a DHCPACK
  defp frame_ack(req_packet, req_addr, state) do
    Packet.frame(
      state.src_mac,
      req_packet.chaddr,
      @server_address,
      req_addr,
      %Packet{
        op: 2,
        xid: req_packet.xid,
        ciaddr: @empty_address,
        yiaddr: req_addr,
        siaddr: @server_address, # Should this be the next-hop addr?
        giaddr: req_packet.giaddr,
        chaddr: req_packet.chaddr,
        options: %{ 53 => 5,
                    1  => @subnet_mask,
                    3  => [@gateway_address],
                    6  => [@dns_address],
                    51 => 86400,
                    54 => @server_address
        }
      }
    )
  end

  # Frame a DHCPNAK
  defp frame_nak(req_packet, req_addr, state) do
    Packet.frame(
      state.src_mac,
      req_packet.chaddr,
      @server_address,
      req_addr,
      %{ op: 2,
         xid: req_packet.xid,
         ciaddr: @empty_address,
         yiaddr: @empty_address,
         siaddr: @empty_address,
         giaddr: @empty_address,
         chaddr: req_packet.chaddr,
         options: %{ 53 => 6,
                     54 => @server_address
         }
      })
  end

  # Send a framed response to a client.
  defp send_response(packet, state) do
    :ok = :packet.send(state.tx_socket, state.ifindex, packet)
  end
end
