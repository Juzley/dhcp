defmodule Dhcp.Test.Binding do
  use ExUnit.Case

  @server_address {192, 168, 0, 2}
  @gateway_address {192, 168, 0, 1}
  @client_1 {11, 22, 33, 44, 55, 66}
  @client_2 {22, 33, 44, 55, 66, 77}
  @client_3 {33, 44, 55, 66, 77, 88}
  @client_4 {44, 55, 66, 77, 88, 99}

  defp check_timer_start time, pid, mac, addr do
    receive do
      {:timer_start, msg_time, args} ->
        assert msg_time == time
        assert args == [pid, mac, addr]

      _ ->
        assert false
    after
      50 -> assert false
    end
  end

  defp check_timer_cancel ref do
    receive do
      {:timer_cancel, cancel_ref} ->
          assert cancel_ref == ref

      _ ->
        assert false
    after
      50 -> assert false
    end
  end

  setup_all do
    :ets.new(:parent_pid, [:set, :named_table, :public])

    :ok
  end

  setup do
    {:ok, pid} = Dhcp.Binding.start(@server_address,
                                    @gateway_address,
                                    {192, 168, 0, 1},
                                    {192, 168, 0, 5},
                                    86400)
    :ets.insert(:parent_pid, {pid, self()})
    on_exit fn -> :ets.delete(:parent_pid, pid) end

    %{bindings: pid}
  end

  test "offers free address", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end

  test "offers same address for duplicate discovers", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end

  test "prefers offering an address that hasn't been offered",
       %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.get_offer_address(pid, @client_2) ==
      {:ok, {192, 168, 0, 4}, 86400}
  end

  test "offers requested address to new clients", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}
  end

  test "ignores requested address if client bound to another address",
    %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.get_offer_address(pid, @client_1, {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end

  test "ignores requested address if client released another address",
    %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.release_address(pid, @client_1, {192, 168, 0, 3}) ==
      :ok
    assert Dhcp.Binding.get_offer_address(pid, @client_1, {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end

  test "prefers requested address to previously offered address",
    %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.get_offer_address(pid, @client_1, {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}
  end

  test "offers a previously allocated address if no others are available",
    %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.get_offer_address(pid, @client_2) ==
      {:ok, {192, 168, 0, 4}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_2, {192, 168, 0, 4}) ==
      {:ok, {192, 168, 0, 4}, 86400}
    assert Dhcp.Binding.get_offer_address(pid, @client_3) ==
      {:ok, {192, 168, 0, 5}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_3, {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}
    assert Dhcp.Binding.release_address(pid, @client_1, {192, 168, 0, 3}) ==
      :ok
    assert Dhcp.Binding.get_offer_address(pid, @client_4) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end

  test "successfully allocates an offered address", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end

  test "starts the lease timer when allocating addresses", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    check_timer_start(86400, pid, @client_1, {192, 168, 0, 3})
  end

  test "successfully releases an allocated address", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.release_address(pid, @client_1, {192, 168, 0, 3}) ==
      :ok
  end

  test "rejects release of an unbound address", %{bindings: pid} do
    assert Dhcp.Binding.release_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:error, :address_not_allocated}
  end

  test "rejects release of wrong address", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.release_address(pid, @client_2, {192, 168, 0, 4}) ==
      {:error, :address_not_allocated}
  end

  test "rejects release of an address bound to a different client",
      %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.release_address(pid, @client_2, {192, 168, 0, 3}) ==
      {:error, :address_not_allocated}
  end

  test "cancels the lease timer when releasing addresses", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    check_timer_start(86400, pid, @client_1, {192, 168, 0, 3})
    assert Dhcp.Binding.release_address(pid, @client_1, {192, 168, 0, 3}) ==
      :ok
    check_timer_cancel([pid, @client_1, {192, 168, 0, 3}])
  end

  test "rejects allocation of a bound address", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_2, {192, 168, 0, 3}) ==
      {:error, :address_allocated}
  end

  test "offers the bound address", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end

  test "handles running out of addresses", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.get_offer_address(pid, @client_2) ==
      {:ok, {192, 168, 0, 4}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_2, {192, 168, 0, 4}) ==
      {:ok, {192, 168, 0, 4}, 86400}
    assert Dhcp.Binding.get_offer_address(pid, @client_3) ==
      {:ok, {192, 168, 0, 5}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_3, {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}
    assert Dhcp.Binding.get_offer_address(pid, @client_4) ==
      {:error, :no_addresses}
  end
end

