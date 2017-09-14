defmodule Dhcp.Server do
  use GenServer
  require Logger

  import Dhcp.Util
  alias Dhcp.Binding
  alias Dhcp.Packet

  @udp Application.get_env(:dhcp, :udp_impl, :gen_udp)

  @dhcp_server_port 67
  @empty_address {0, 0, 0, 0}
  @broadcast_address {255, 255, 255, 255}

  @server_address Application.fetch_env!(:dhcp, :server_address)
  @gateway_address Application.fetch_env!(:dhcp, :gateway_address)
  @dns_address Application.fetch_env!(:dhcp, :dns_address)
  @subnet_mask Application.fetch_env!(:dhcp, :subnet_mask)

  # TODO: unicast rx socket
  # TODO: Broadcast bit handling
  # TODO: DHCPInform, DHCPDecline

  # Client API

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # Server API

  def init(:ok) do
    result = {:ok, %{}}
             |> init_rx_socket()
             |> init_tx_socket()
             |> init_src_mac()

    case result do
      {:error, reason} ->
        {:stop, reason}

      _ ->
        result
    end
  end

  # Initialize the receive socket.
  defp init_rx_socket({:ok, state}) do
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
        Logger.error "Ignoring DHCP message received with no message type"

      msg_type ->
        Logger.debug "Ignoring DHCP message type #{msg_type}"
    end

    state
  end

  # Handle a discovery packet.
  def handle_discover(state, packet) do
    requested_address = Map.get(packet.options, 50)
    requested_lease = Map.get(packet.options, 51)
    Logger.info(
      "Received Discover message from #{mac_to_string(packet.chaddr)}," <>
      " requested address  #{ipv4_to_string(requested_address)}")

    offer_info = Binding.get_offer_address(Dhcp.Binding,
                                           packet.chaddr,
                                           requested_address,
                                           requested_lease)
    case offer_info do
      {:ok, offer_address, offer_lease} ->
        Logger.info(
          "Offering #{ipv4_to_string(offer_address)} to" <>
          " #{mac_to_string(packet.chaddr)}")
        frame_offer(packet, offer_address, offer_lease, state)
        |> send_response(state)

      {:error, reason} ->
        Logger.error(
          "Failed to get offer address for #{mac_to_string(packet.chaddr)}:" <>
          " #{reason}")
	end
  end

  # Handle a request packet.
  defp handle_request(state, packet) do
    requested_address = Map.get(packet.options, 50)
    server_address = Map.get(packet.options, 54)

    Logger.info(
      "Received Request message from #{mac_to_string(packet.chaddr)}" <>
      " to #{ipv4_to_string(server_address)}, requested address" <>
      " #{ipv4_to_string(requested_address)}")

    if server_address == @server_address do
      result = Binding.allocate_address(Dhcp.Binding,
                                        packet.chaddr,
                                        requested_address)
      case result do
        :ok ->
          Logger.info(
            "Allocated #{ipv4_to_string(requested_address)} to" <>
            " #{mac_to_string(packet.chaddr)}, sending Ack")
        frame_ack(packet, requested_address, state) |> send_response(state)

        {:error, reason} ->
          Logger.error(
            "Failed to allocate #{ipv4_to_string(requested_address)} to" <>
            " #{mac_to_string(packet.chaddr)}: #{reason}, sending Nak")
        frame_nak(packet, requested_address, state) |> send_response(state)
      end
    else
      # Forget any offers etc if the request is for a different server.
      Binding.cancel_offer(Dhcp.Binding,
                           packet.chaddr)
    end
  end

  # Handle a release packet.
  defp handle_release(state, packet) do
    server_address = Map.get(packet.options, 54)
    Logger.info(
      "Received Release message from #{mac_to_string(packet.chaddr)} to" <>
      " #{ipv4_to_string(server_address)}, released address" <>
      " #{ipv4_to_string(packet.ciaddr)}")

    if server_address == @server_address do
      result = Binding.release_address(Dhcp.Binding,
                                       packet.chaddr,
                                       packet.ciaddr)
      case result do
        :ok ->
          Logger.info(
            "Released #{ipv4_to_string(packet.ciaddr)} from" <>
            " #{mac_to_string(packet.chaddr)}")

        {:error, reason} ->
          Logger.error(
            "Failed to release #{ipv4_to_string(packet.ciaddr)} from" <>
            " #{mac_to_string(packet.chaddr)}: #{reason}")
        end
    end
  end

  # Frame a DHCPOFFER
  defp frame_offer(req_packet, offer_addr, offer_lease, state) do
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
                    51 => offer_lease,
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
        siaddr: @server_address,
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
