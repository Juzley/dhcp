defmodule Dhcp.Server do
  use GenServer
  require Logger

  @udp Application.get_env(:dhcp, :udp_impl, :gen_udp)

  @dhcp_server_port 67
  @dhcp_client_port 68

  @empty_address {0, 0, 0, 0}
  @server_address {192, 168, 0, 1}
  @gateway_address {192, 168, 0, 1}
  @subnet_mask {255, 255, 255, 0}
  @min_address {192, 168, 0, 1}
  @max_address {192, 168, 0, 255}

  @broadcast_address_tuple {255, 255, 255, 255}

  # Client API

  def start do
    GenServer.start_link(__MODULE__, :ok)
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

  defp init_rx_socket({:ok, state}) do
    case result = @udp.open(@dhcp_server_port) do
      {:ok, socket} ->
        {:ok, %{state | rx_socket: socket}}

      _ ->
        result
    end
  end
  defp init_rx_socket(err), do: err

  defp init_tx_socket({:ok, state}) do
    case result = :packet.socket(0x800) do
      {:ok, socket} ->
        intf = :packet.default_interface()
        ifindex = :packet.ifindex(socket, intf)
        {:ok, %{state | tx_socket: socket, ifindex: ifindex}}

      _ ->
        result
    end
  end
  defp init_tx_socket(err), do: err

  defp init_src_mac({:ok, state}) do
    mac_info =
      :packet.default_interface()
      |> List.first
      |> :inet.ifget([:hwaddr])

    case mac_info do
      {:ok, [hwaddr: mac]} ->
        {:ok, %{state | src_mac: List.to_tuple(mac)}}

      _ ->
        {:error, :if_mac_not_found}
    end
  end
  defp init_src_mac(err), do: err

  defp init_binding({:ok, state}) do
    result = Dhcp.Binding.start(@server_address, @gateway_address,
                                @min_address, @max_address)
    case result do
      {:ok, bindings} ->
        {:ok, %{state | bindings: bindings}}

      _ ->
        result
    end
  end
  defp init_binding(err), do: err

  # UDP packet callback.
  def handle_info({_, _socket}, state), do: {:noreply, state}
  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    case Dhcp.Packet.parse(data) do
      {:ok, packet} ->
        new_state = handle_packet(state, packet)
        {:noreply, new_state}

      {:error, _} ->
        {:noreply, state}
    end
  end

  # Handle a successfully parsed DHCP packet.
  defp handle_packet(state, packet) do
    case Map.get(packet.options, 53) do
      1 ->
        handle_discover(state, packet)

      3 ->
        handle_request(state, packet)

      msg_type ->
        Logger.debug "Ignoring DHCP message type #{msg_type}"
    end

    state
  end

  # Handle a discovery packet.
  def handle_discover(state, packet) do
    requested_address = Map.get(packet.options, 50)
    offer_address = Dhcp.Binding.get_offer_address(state.bindings,
                                                   packet.chaddr,
                                                   requested_address)
    offer_packet = Dhcp.Packet.frame(%{
      op: 2,
      xid: packet.xid,
      ciaddr: @empty_address,
      yiaddr: offer_address,
      siaddr: @server_address,
      giaddr: @gateway_address,
      chaddr: packet.chaddr,
      options: %{
        53 => 2,
        1  => @subnet_mask,
        51 => 86400,
        54 => @server_address
      }
    })

    # TODO: unicast replies if the client has indicated a preference?
    @udp.send(state.socket,
              @broadcast_address_tuple,
              @dhcp_client_port,
              Dhcp.Packet.frame(offer_packet))

    state
  end

  # Handle a request packet.
  defp handle_request(state, _packet) do
    state
  end

  defp send_response do
  end
end
