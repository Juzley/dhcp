defmodule Dhcp.Server do
  use GenServer
  require Logger

  @udp Application.get_env(:dhcp, :udp_impl, :gen_udp)

  @dhcp_server_port 67
  @dhcp_client_port 68

  @empty_address_bytes <<0::32>>
  @server_address_bytes <<192::8, 168::8, 0::8, 1::8>>
  @gateway_address_bytes <<192::8, 168::8, 0::8, 1::8>>
  @subnet_mask_bytes <<255::8, 255::8, 255::8, 0::8>>

  @broadcast_address_tuple {255, 255, 255, 255}

  # Client API

  def start do
    GenServer.start_link(__MODULE__, :ok)
  end

  # Server API

  def init(:ok) do
    case @udp.open(@dhcp_server_port) do
      {:ok, socket} ->
        {:ok, %{socket: socket, bindings: %{}}}
      {:error, reason} ->
        {:stop, reason}
    end
  end

  # UDP packet callback.
  def handle_info({_, _socket}, state), do: {:noreply, state}
  def handle_info({:udp, socket, ip, _port, data}, state) do
    case Dhcp.Packet.parse(data) do
      {:ok, packet} ->
        new_state = handle_packet(state, packet)
        {:noreply, new_state}

      {:error, reason} ->
        {:noreply, state}
    end
  end

  # Handle a successfully parsed DHCP packet.
  defp handle_packet(state, packet) do
    case Map.get(packet.options, 53) do
      1 ->
        handle_discover(state, packet)

      msg_type ->
        Logger.debug "Ignoring DHCP message type #{msg_type}"
    end

    state
  end

  # Handle a discovery packet.
  defp handle_discover(state, packet) do
    requested_address = Map.get(packet.options, 50)

    offer_packet = Dhcp.Packet.frame(%{
      op: 2,
      xid: packet.xid,
      ciaddr: @empty_address_bytes,
      yiaddr: offer_address(state, packet.chaddr, requested_address),
      siaddr: @server_address_bytes,
      giaddr: @gateway_address_bytes,
      chaddr: packet.chaddr,
      options: %{
        53 => 2,
        1  => @subnet_mask,
        51 => 86400,
        54 => @server_address_bytes
      }
    })

    # TODO: unicast replies if the client has indicated a preference?
    @udp.send(state.socket,
              @broadcast_address_tuple,
              @dhcp_client_port,
              Dhcp.Packet.frame(offer_packet))

    state
  end

  # Find an offer address.
  defp offer_address(state, client_mac, client_req) do
    unavailable = unavailable_addresses(state)

    # TODO: Hrm
    case Map.get(state.bindings, client_mac) do
      nil ->
        if MapSet.member?(unavailable, client_req) do
          free_address(state)
        else
          client_req
        end

      addr ->
        addr
    end
  end

  # Get a MapSet of currently bound addresses.
  defp bound_addresses(state) do
    MapSet.new(Map.values(state.bindings))
  end

  # Find a free address
  defp free_address(state) do
    Enum.filter(address_pool, &(address_unavailable?(state, &1))) |> List.first
  end

  # Determine whether a given address is unavailable
  defp address_unavailable?(state, addr) do
    MapSet.member?(unavailable_addresses(state), addr)
  end

  # Get a MapSet of current unavailable addresses.
  defp unavailable_addresses(state) do
    state
    |> bound_addresses
    |> MapSet.put(@server_address_bytes)
    |> MapSet.put(@gateway_address_bytes)
  end

  # Get the current full address pool for the subnet.
  defp address_pool do
    for n <- 1..255, do: <<192::8, 168::8, 0::8, n::8>>
  end
end
