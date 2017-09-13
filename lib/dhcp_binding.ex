defmodule Dhcp.Binding do
  @moduledoc """
    This module implements a GenServer which manages DHCP address bindings.
  """
  
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

  Returns {`:ok`, address, lease} if the address was allocated or
  {`:error`, `:address_allocated`} if the address was already allocated.
  """
  def allocate_address(pid, client_mac, client_addr, req_lease \\ nil) do
    GenServer.call(pid, {:allocate, client_mac, client_addr, req_lease})
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
  def init({server_address, gateway_address, min_address, max_address,
    max_lease}) do
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
    |> handle_offer(client_mac, req_addr, req_lease, state)
  end

  # Handle an 'allocate' call.
  def handle_call({:allocate, client_mac, addr, req_lease}, _from, state) do
    Map.get(state.bindings, client_mac)
    |> handle_allocate(client_mac, addr, req_lease, state)
  end

  # Handle a 'release' call.
  def handle_call({:release, client_mac, client_addr}, _from, state) do
    case Map.fetch(state.bindings, client_mac) do
      # Release the binding only if the supplied address was actually allocated
      # to this client.
      {:ok, {:allocated, %{addr: ^client_addr}}} ->
        state
        |> cancel_timer(client_mac)
        |> update_bindings(client_mac, :released, client_addr)
        |> (&({:reply, :ok, &1})).()

      _ ->
        {:reply, {:error, :address_not_allocated}, state}

    end
  end

  # Handle a 'cancel offer' cast.
  def handle_cast({:cancel_offer, client_mac}, state) do
    # The client is using a different DHCP server, release the address
    # completely. If the address was actually allocated, cancel the timer.
    state
    |> cancel_timer(client_mac)
    |> delete_binding(client_mac)
    |> (&({:noreply, &1})).()
  end

  # Handle an offer for a currently bound client.
  defp handle_offer({:allocated, %{addr: addr, lease_expiry: lease_expiry}},
                   _client_mac, _req_addr, req_lease, state) do
    new_lease = if req_lease do
      min(req_lease, state.max_lease)
    else
      lease_expiry - unix_now()
    end

    make_reply(state, addr, new_lease)
  end

  # Handle an offer for a client for which there is no existing binding info.
  defp handle_offer(_binding = nil, client_mac, req_addr, req_lease, state) do
    new_lease = offer_lease(state, req_lease)
    new_addr = free_address(state)

    cond do
      address_available?(state, req_addr) ->
        state
        |> update_bindings(client_mac, :offered, req_addr, new_lease)
        |> make_reply(req_addr, new_lease)

      new_addr ->
        state
        |> update_bindings(client_mac, :offered, new_addr, new_lease)
        |> make_reply(new_addr, new_lease)

      true ->
        {:reply, {:error, :no_addresses}, state}
    end
  end

  # Handle an offer for a client whose lease has expired.
  defp handle_offer({:released, %{addr: addr}},
                   client_mac, _req_addr, req_lease, state) do
    new_lease = offer_lease(state, req_lease)
    new_addr = free_address(state)

    cond do
      address_available?(state, addr) ->
        # The old address is still available.
        state
        |> update_bindings(client_mac, :offered, addr, new_lease)
        |> make_reply(addr, new_lease)

      new_addr ->
        # Use a newly allocated address.
        state
        |> update_bindings(client_mac, :offered, new_addr, new_lease)
        |> make_reply(addr, new_lease)

      true ->
        # No addresses left.
        {:reply, {:error, :no_addresses}, state}
    end
  end

  # Handle an offer for a client which we have previously offered an
  # address for.
  defp handle_offer({:offered, %{addr: addr}},
                   client_mac, req_addr, req_lease, state) do
    new_lease = offer_lease(state, req_lease)
    new_addr = free_address(state)

    cond do
      address_available?(state, req_addr) ->
        # The requested address is acceptable.
        state
        |> update_bindings(client_mac, :offered, req_addr, new_lease)
        |> make_reply(req_addr, new_lease)

      address_available?(state, addr) ->
        # The address that was already offered is still acceptable.
        state
        |> update_bindings(client_mac, :offered, addr, new_lease)
        |> make_reply(addr, new_lease)

      new_addr ->
        # Use a newly allocated address.
        state
        |> update_bindings(client_mac, :offered, new_addr, new_lease)
        |> make_reply(new_addr, new_lease)

      true ->
        # No addresses left.
        {:reply, {:error, :no_addresses}, state}
    end
  end

  # Handle a request from a client for which we have no state.
  defp handle_allocate(_binding=nil, client_mac, req_addr, req_lease, state) do
    # We don't expect this to happen, but handle it as if we had made an offer.
    new_lease = offer_lease(state, req_lease)
    handle_allocate({:offered, %{lease_time: new_lease}},
                    client_mac, req_addr, req_lease, state)
  end

  # Handle a request from a client to which we have made an offer.
  defp handle_allocate({:offered, %{lease_time: lease_time}},
                       client_mac, addr, _req_lease, state) do
    if address_available?(state, addr) do
      # TODO: Should we have started the expiry time from when we offered?
      expiry = unix_now() + lease_time

      state
      |> update_bindings(client_mac, :allocated, addr, lease_time, expiry)
      |> start_timer(client_mac, addr, lease_time)
      |> make_reply(addr, lease_time)
    else
      {:reply, {:error, :address_allocated}, state}
    end
  end

  # Handle a request from a client which is already bound.
  defp handle_allocate(
    {:allocated, %{addr: cur_addr, lease_expiry: lease_expiry}},
    client_mac, _addr, req_lease, state) do
    if req_lease do
      # Extending an existing lease.
      new_lease = min(req_lease, state.max_lease)

      state
      |> restart_timer(client_mac, cur_addr, new_lease)
      |> make_reply(cur_addr, new_lease)

    else
      # Return the current information.
      make_reply(state, cur_addr, lease_expiry - unix_now())
    end
  end

  # Make a genserver reply with lease info, for handling offer and allocate
  # calls.
  defp make_reply(state, addr, lease), do: {:reply, {:ok, addr, lease}, state}

  # Update the state with a new binding, returning the new state.
  defp update_bindings(state, client_mac, class, addr, lease_time \\ nil,
                       lease_expiry \\ nil) do
    binding_data = %{addr: addr,
                     lease_time: lease_time,
                     lease_expiry: lease_expiry}
    bindings = Map.put(state.bindings, client_mac, {class, binding_data})
    %{state | bindings: bindings}
  end

  # Delete a binding, returning the new state.
  defp delete_binding(state, client_mac) do
    %{state | bindings: Map.delete(state.bindings, client_mac)}
  end

  # Start a lease expiry timer for a given client, and return the updated
  # state.
  defp start_timer(state, client_mac, addr, period) do
    {:ok, timer_ref} = @timer.apply_after(period,
                                          Dhcp.Binding,
                                          &release_address/3,
                                          [self(), client_mac, addr])
    %{state | timers: Map.put(state.timers, client_mac, timer_ref)}
  end

  # Cancel any timer associated with a given client, and return the updated
  # state.
  defp cancel_timer(state, client_mac) do
    case Map.get(state.timers, client_mac) do
      nil ->
        state

      timer_ref ->
        @timer.cancel(timer_ref)
        %{state | timers: Map.delete(state.timers, client_mac)}
    end
  end

  # Restart the timer associated with a given client with a new lease, and
  # return the updated state.
  defp restart_timer(state, client_mac, addr, period) do
    state
    |> cancel_timer(client_mac)
    |> start_timer(client_mac, addr, period)
  end

  # Determine the length of lease to offer to a client.
  defp offer_lease(state, _req_lease=nil), do: state.max_lease
  defp offer_lease(state, req_lease), do: min(req_lease, state.max_lease)

  # Find a free address - prefer addresses that haven't already been offered.
  defp free_address(state) do
    state
    |> address_pool()
    |> Enum.filter(&(address_available?(state, &1)))
    |> Enum.sort_by(&(if address_offered?(state, &1), do: 0, else: 1))
    |> List.first
  end

  # Determine whether a given address is available.
  defp address_available?(_state, nil), do: false
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
    |> Enum.filter(fn({c, _}) -> c == class end)
    |> Enum.map(fn({_, %{addr: a}}) -> a end)
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

  # Get a unix timestamp representing the time now.
  defp unix_now do
    Timex.now() |> Timex.to_unix()
  end
end
