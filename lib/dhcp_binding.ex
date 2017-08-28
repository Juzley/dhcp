defmodule Dhcp.Binding do
  @moduledoc """
    This module implements a GenServer which manages DHCP address bindings.
  """

  use GenServer

  @timer Application.get_env(:dhcp, :timer_impl, :timer)

  # Client API

  @doc """
  Starts the GenServer.
  """
  def start(server_address, gateway_address) do
    GenServer.start_link(__MODULE__, {server_address, gateway_address})
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

  def init({server_address, gateway_address}) do
    {:ok, %{server_address: server_address,
            gateway_address: gateway_address,
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
    binding = Map.fetch(state.bindings, client_mac)
    req_acceptable = client_req != nil and address_available?(state, client_req)
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
    address_pool()
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

  defp allocated_addresses(state), do: get_addresses(state, :allocated)

  defp offered_addresses(state), do: get_addresses(state, :offered)

  defp get_addresses(state, class) do
    Map.values(state.bindings)
    |> Enum.filter(fn({_, c}) -> c == class end)
    |> Enum.map(fn({a, _}) -> a end)
    |> MapSet.new()
  end

  # Get the current full address pool for the subnet.
  defp address_pool do
    for n <- 1..255, do: <<192::8, 168::8, 0::8, n::8>>
  end
end
