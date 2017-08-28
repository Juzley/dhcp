defmodule Dhcp.Binding do
  @moduledoc """
    This module implements a GenServer which manages DHCP address bindings.
  """

  use GenServer
  use Bitwise

  @timer Application.get_env(:dhcp, :timer_impl, :timer)

  # Client API

  @doc """
  Starts the GenServer.
  """
  def start(server_address, gateway_address, min_addr, max_addr) do
    GenServer.start_link(__MODULE__,
                         {server_address, gateway_address, min_addr, max_addr})
  end

  @doc """
  Get an address to offer to client with MAC `client_mac`, optionally
  considering an address requested by the client.
  """
  def get_offer_address(pid, client_mac, client_req \\ nil) do
    GenServer.call(pid, {:offer, client_mac, client_req})
  end

  @doc """
  Allocate an address to a client with MAC `client_mac`, if the address is
  not already allocated.

  Returns `:ok` if the address was allocated or {`:error`, `:address_allocated}
  if the address was already allocated.
  """
  def allocate_address(pid, client_mac, client_addr) do
    GenServer.call(pid, {:allocate, client_mac, client_addr})
  end

  def release_address(pid, client_mac, client_addr) do
    GenServer.call(pid, {:release, client_mac, client_addr})
  end


  # Server API

  def init({server_address, gateway_address, min_address, max_address}) do
    {:ok, %{server_address: server_address,
            gateway_address: gateway_address,
            min_address: min_address,
            max_address: max_address,
            bindings: %{}}}
  end

  def handle_call({:offer, client_mac, client_req}, _from, state) do
    addr = offer_address(client_mac, client_req, state)
    bindings = Map.put(state.bindings, client_mac, {addr, :offered})
    {:reply, {:ok, addr}, %{state | bindings: bindings}}
  end

  def handle_call({:allocate, client_mac, addr}, _from, state) do
    if address_available?(state, addr) do
      {:ok, timer_ref} = @timer.apply_after(86400,
                                            Dhcp.Binding,
                                            &release_address/3,
                                            [self(), client_mac, addr])
      bindings = Map.put(state.bindings,
                         client_mac,
                         {addr, :allocated, timer_ref})

      {:reply, :ok, %{state | bindings: bindings}}
    else
      {:reply, {:error, :address_allocated}}
    end
  end

  def handle_call({:release, client_mac, client_addr}, _from, state) do
    # TODO: Check that the address was actually allocated to the client
    # TODO: Cancel timer
    bindings = Map.put(state.bindings, client_mac, {client_addr, :released})
    {:reply, :ok, %{state | bindings: bindings}}
  end

  defp offer_address(client_mac, client_req, state) do
    # TODO: Check the client req address is in the right subnet.
    req_acceptable =
     client_req != nil and address_available?(state, client_req)

    case Map.fetch(state.bindings, client_mac) do
      {:ok, {addr, class}} ->
        cond do
          class in [:allocated, :released] ->
            addr

          req_acceptable ->
            client_req

          class == :offered ->
            addr

          true ->
            free_address(state)
        end

      :error ->
        if req_acceptable, do: client_req, else: free_address(state)
    end
  end

  # Find a free address - prefer addresses that haven't already been offered.
  defp free_address(state) do
    # TODO: Handle running out of addresses.
    state
    |> address_pool()
    |> Enum.filter(&(address_available?(state, &1)))
    |> Enum.sort_by(&(if address_offered?(state, &1), do: 0, else: 1))
    |> List.first
  end

  # Determine whether a given address is available
  defp address_available?(state, addr) do
    not MapSet.member?(unavailable_addresses(state), addr)
  end

  defp address_offered?(state, addr) do
    not MapSet.member?(offered_addresses(state), addr)
  end

  # Get a MapSet of currently unavailable addresses.
  defp unavailable_addresses(state) do
    state
    |> allocated_addresses
    |> MapSet.put(state.server_address)
    |> MapSet.put(state.gateway_address)
  end

  # Get a MapSet of all allocated addresses.
  defp allocated_addresses(state), do: get_addresses(state, :allocated)

  # Get a MapSet of all offered addresses.
  defp offered_addresses(state), do: get_addresses(state, :offered)

  # Get a MapSet of all addresses of a particular binding class.
  defp get_addresses(state, class) do
    Map.values(state.bindings)
    |> Enum.filter(fn({_, c}) -> c == class end)
    |> Enum.map(fn({a, _}) -> a end)
    |> MapSet.new()
  end

  # Get the current full address pool for the subnet.
  defp address_pool state do
    min = address_to_int(state.min_address)
    max = address_to_int(state.max_address)
    for n <- min..max, do: int_to_address(n)
  end

  # Convert an address in binary format to an integer.
  defp address_to_int {oct4, oct3, oct2, oct1} do
    (oct4 <<< 24) ||| (oct3 <<< 16) ||| (oct2 <<< 8) ||| oct1
  end

  # Convert an address in integer format to binary format.
  defp int_to_address addr do
    oct4 = addr >>> 24
    oct3 = (addr >>> 16) &&& 0xff
    oct2 = (addr >>> 8) &&& 0xff
    oct1 = addr &&& 0xff
    {oct4, oct3, oct2, oct1}
  end
end
