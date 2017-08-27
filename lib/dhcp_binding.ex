defmodule Dhcp.Binding do
  use GenServer

  # Client API

  def start(server_address, gateway_address) do
    GenServer.start_link(__MODULE__, {server_address, gateway_address})
  end

  def get_offer_address(pid, client_mac, client_req) do
    GenServer.call(pid, {:offer, client_mac, client_req})
  end


  # Server API

  def init({server_address, gateway_address}) do
    {:ok, %{server_address: server_address,
            gateway_address: gateway_address,
            bindings: %{},
            expired: %{},
            offered: MapSet.new()}}
  end

  def handle_call({:offer, client_mac, client_req}, _from, state) do
    addr = offer_address(client_mac, client_req, state)
    offered = MapSet.put(state.offered, addr)
    {:reply, addr, %{state | offered: offered }}
  end

  defp offer_address(client_mac, client_req, state) do
    offer_address_check_bound(client_mac, state)
    |> offer_address_check_expired(client_mac, state)
    |> offer_address_check_requested(client_req, state)
    |> offer_address_check_free(state)
  end

  defp offer_address_check_bound(client_mac, state) do
    Map.get(state.bindings, client_mac)
  end

  defp offer_address_check_expired(nil, client_mac, state) do
    if addr = Map.get(state.expired, client_mac) do
      if address_available?(state, addr), do: addr, else: nil
    else
      nil
    end
  end

  defp offer_address_check_expired(offer_addr, _client_mac, _state) do
    offer_addr
  end

  defp offer_address_check_requested(nil, state, nil), do: nil

  defp offer_address_check_requested(nil, client_req, state) do
    if address_available?(state, client_req) do
      client_req
    else
      nil
    end
  end

  defp offer_address_check_requested(offer_addr, _client_req, _state) do
    offer_addr
  end

  defp offer_address_check_free(nil, state) do
    free_address(state)
  end

  defp offer_address_check_free(offer_addr, _state) do
    offer_addr
  end

  # Get a MapSet of currently bound addresses.
  defp bound_addresses(state) do
    MapSet.new(Map.values(state.bindings))
  end

  # Find a free address - prefer addresses that haven't already been offered.
  defp free_address(state) do
    address_pool
    |> Enum.filter(&(address_available?(state, &1)))
    |> Enum.sort_by(&(if MapSet.member?(state.offered, &1), do: 1, else: 0))
    |> List.first
  end

  # Determine whether a given address is available
  def address_available?(state, addr) do
    not MapSet.member?(unavailable_addresses(state), addr)
  end

  # Get a MapSet of currently unavailable addresses.
  def unavailable_addresses(state) do
    MapSet.new(Map.values(state.bindings))
    |> MapSet.put(state.server_address)
    |> MapSet.put(state.gateway_address)
  end

  # Get the current full address pool for the subnet.
  defp address_pool do
    for n <- 1..255, do: <<192::8, 168::8, 0::8, n::8>>
  end
end
