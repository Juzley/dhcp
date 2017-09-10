defmodule Dhcp.Binding do
  @moduledoc """
    This module implements a GenServer which manages DHCP address bindings.
  """
  
  # TODO: Lease times - or maybe handle in the server?
  # TODO: Infinite lease requests
  # TODO: Persist bindings to disk for restart.

  use GenServer
  use Bitwise

  @timer Application.get_env(:dhcp, :timer_impl, :timer)

  # Client API

  @doc """
  Starts the GenServer.
  """
  def start(server_address, gateway_address, min_addr, max_addr, max_lease) do
    GenServer.start_link(
      __MODULE__,
      {server_address, gateway_address, min_addr, max_addr, max_lease})
  end

  @doc """
  Stops the GenServer.
  """
  def stop(pid) do
    GenServer.stop(pid)
  end

  @doc """
  Get an address to offer to client with MAC `client_mac`, optionally
  considering an address requested by the client.

  Returns {`:ok`, address, lease} with the address to offer if successful, or
  {`:
  """
  def get_offer_address(pid, client_mac, req_addr \\ nil, req_lease \\ nil) do
    GenServer.call(pid, {:offer, client_mac, req_addr, req_lease})
  end

  @doc """
  Cancel an offer made to a client (i.e. mark it as not offered). This is used
  when the server sees a client accept (i.e. request) and address from another
  server.

  Returns `:ok`.
  """
  def cancel_offer(pid, client_mac) do
    GenServer.cast(pid, {:cancel_offer, client_mac})
    :ok
  end

  @doc """
  Allocate an address to a client with MAC `client_mac`, if the address is
  not already allocated.

  Returns `:ok` if the address was allocated or
  {`:error`, `:address_allocated`} if the address was already allocated.
  """
  def allocate_address(pid, client_mac, client_addr) do
    GenServer.call(pid, {:allocate, client_mac, client_addr})
  end

  @doc """
  Release the address bound to a client.

  Returns `:ok` in the address was released, or
  {`:error`, `:address_not_allocated`} if the address wasn't allocated to the
  client.
  """
  def release_address(pid, client_mac, client_addr) do
    GenServer.call(pid, {:release, client_mac, client_addr})
  end


  # Server API

  # Initialize an instance of the binding GenServer.
  def init({server_address, gateway_address, min_address, max_address}) do
    {:ok, %{server_address: server_address,
            gateway_address: gateway_address,
            min_address: min_address,
            max_address: max_address,
            max_lease: max_lease,
            bindings: %{},
            timers: %{}}}
  end

  # Handle an 'offer' call.
  # From the RFC, consider addresses to offer in the following order:
  # 1. The address that is currently bound to the client.
  # 2. The address that was previously bound to the client.
  # 3. The address requested by the client.
  # 4. A free address from the pool.
  # Before step 4, we also consider whether we have already offered the
  # client an address, and offer the same one if so.
  def handle_call({:offer, client_mac, req_addr, req_lease}, _from, state) do
    Map.get(state.bindings, client_mac)
    |> handle_offer(req_addr, req_lease, state)
  end

  # Handle an offer for a currently bound client.
  def handle_offer({:allocated, %{addr: addr, lease_expiry: lease_expiry}},
                   _req_addr, req_lease, state) do
    new_lease = if req_lease do
      min(req_lease, state.max_lease)
    else
      lease_expiry - Timex.now().to_unix()
    end

    {:reply, {:ok, addr, new_lease}, state}
  end

  # Handle an offer for a client for which there is no existing binding info.
  def handle_offer(_binding = nil, req_addr, req_lease, state) do
    new_lease = if req_lease and req_lease < state.max_lease, do: req_lease,
      else: state.max_lease
    new_addr = free_address(state)

    cond do
      address_available?(state, req_addr) ->
        binding_info = {:offered, %{addr: req_addr, lease_time: new_lease}}
        bindings = Map.put(state.bindings, client_mac, binding_info)

        {:reply, {:ok, req_addr, new_lease}, %{state | bindings: bindings}}

      new_addr ->
        binding_info = {:offered, %{addr: new_addr, lease_time: new_lease}}
        bindings = Map.put(state.bindings, client_mac, binding_info)

        {:reply, {:ok, new_addr, new_lease}, %{state | bindings: bindings}}

      true ->
        {:reply, {:error, :no_addresses}, state}
    end
  end

  # Handle an offer for a client whose lease has expired.
  def handle_offer({:released, %{addr: addr}}, req_addr, req_lease, state) do
    new_lease = if req_lease and req_lease < state.max_lease, do: req_lease,
      else: state.max_lease
    new_addr = free_address(state)

    cond do
      address_available?(state, addr) ->
        # The old address is still available.
        binding_info = {:offered, %{addr: addr, lease_time: new_lease}}
        bindings = Map.put(state.bindings, client_mac, binding_info)

        {:reply, {:ok, addr, new_lease}, %{state | bindings: bindings}}

      new_addr ->
        # Use a newly allocated address.
        binding_info = {:offered, %{addr: new_addr, lease_time: new_lease}}
        bindings = Map.put(state.bindings, client_mac, binding_info)

        {:reply, {:ok, new_addr, new_lease} %{state | bindings: bindings}}

      true ->
        # No addresses left.
        {:reply, {:error, :no_addresses}, state}
    end
  end

  # Handle an offer for a client which we have previously offered an
  # address for.
  def handle_offer({:offered, %{addr: addr}}, req_addr, req_lease, state) do
    new_lease = if req_lease and req_lease < state.max_lease, do: req_lease,
      else: state.max_lease
    new_addr = free_address(state)

    cond do
      address_available?(state, req_addr) ->
        # The requested address is acceptable.
        binding_info = {:offered, %{addr: req_addr, lease_time: new_lease}}
        bindings = Map.put(state.bindings, client_mac, binding_info)

        {:reply, {:ok, req_addr, new_lease}, %{state | bindings: bindings}}

      address_available?(state, addr) ->
        # The address that was already offered is still acceptable.
        binding_info = {:offered, %{addr: addr, lease_time: new_lease}}
        bindings = Map.put(state.bindings, client_mac, binding_info)

        {:reply, {:ok, addr, new_lease}, %{state | bindings: bindings}}

      new_addr ->
        # Use a newly allocated address.
        binding_info = {:offered, %{addr: new_addr, lease_time: new_lease}}
        bindings = Map.put(state.bindings, client_mac, binding_info)

        {:reply, {:ok, addr, new_lease}, %{state | bindings: bindings}}

      true ->
        # No addresses left.
        {:reply, {:error, :no_addresses}, state}
    end
  end
         
  # Handle an 'allocate' call.
  def handle_call({:allocate, client_mac, addr}, _from, state) do
    if address_available?(state, addr) do
      {:ok, timer_ref} = @timer.apply_after(86400,
                                            Dhcp.Binding,
                                            &release_address/3,
                                            [self(), client_mac, addr])
      bindings = Map.put(state.bindings,
                         client_mac,
                         {addr, :allocated, {timer_ref, 86400}})

      {:reply, :ok, %{state | bindings: bindings}}
    else
      {:reply, {:error, :address_allocated}, state}
    end
  end

  # Handle a 'release' call.
  def handle_call({:release, client_mac, client_addr}, _from, state) do
    case Map.fetch(state.bindings, client_mac) do
      {:ok, {^client_addr, {:allocated, client_info}}} ->

        # Cancel the timer.
        Map.get(state.timers, client_mac)
        |> @timer.cancel()

        bindings = Map.put(state.bindings,
                           client_mac,
                           {client_addr, {:released, client_info}})
        {:reply, :ok, %{state | bindings: bindings}}

      _ ->
        {:reply, {:error, :address_not_allocated}, state}

    end
  end

  # Handle a 'cancel offer' cast.
  def handle_cast({:cancel_offer, client_mac}, state) do
    # If the address was actually allocated, cancel the timer.
    Map.fetch(state.timers, client_mac)
    |> @timer.cancel()

    # The client is using a different DHCP server, release the address
    # completely.
    {:noreply, %{state | bindings: Map.delete(state.bindings, client_mac)}}
  end

  # Determine the lease time to respond to an offer request with.
  defp offer_lease(client_mac, client_req, state) do
    if client_req do
      # The client has requested a lease time - clamp it to the max lease time.
      min([client_req, state.max_lease])
    else
      case Map.fetch(state.bindings, client_mac) do
        {:ok, {_addr, :allocated, {_timer, expiry}}} ->
          # If there is already an address allocated, return the remaining
          # time.
          Timex.diff(Timex.now, expiry, :seconds)

        _ ->
          state.max_lease
      end
    end
  end

  # Find a free address - prefer addresses that haven't already been offered.
  defp free_address(state) do
    state
    |> address_pool()
    |> Enum.filter(&(address_available?(state, &1)))
    |> Enum.sort_by(&(if address_offered?(state, &1), do: 0, else: 1))
    |> List.first
  end

  # Determine whether a given address is available.
  defp address_available?(state, nil), do: false
  defp address_available?(state, addr) do
    Enum.member?(address_pool(state), addr) and not
      MapSet.member?(unavailable_addresses(state), addr)
  end

  # Determine whether a given address has been offered.
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
    |> Enum.filter(fn({_, c, _}) -> c == class end)
    |> Enum.map(fn({a, _, _}) -> a end)
    |> MapSet.new()
  end

  # Get the current full address pool for the subnet, as a list.
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
