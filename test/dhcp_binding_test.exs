defmodule Dhcp.Test.Binding do
  use ExUnit.Case, async: false

  @client_1 {11, 22, 33, 44, 55, 66}
  @client_2 {22, 33, 44, 55, 66, 77}
  @client_3 {33, 44, 55, 66, 77, 88}
  @client_4 {44, 55, 66, 77, 88, 99}

  defp check_timer_start time, pid, mac, addr do
    assert_received({:timer_start, ^time, [^pid, ^mac, ^addr]})
  end

  defp check_timer_cancel ref do
    assert_received({:timer_cancel, ^ref})
  end

  defp set_timestamp t do
    :ets.insert(:timex_mock, {:timestamp, t})
  end

  defp cleanup_dets do
    try do 
      :dets.delete_all_objects("bindings.dets")
    rescue
      _ -> :ok
    end
  end

  setup do
    true = Process.register(self(), :test_process)
    :timex_mock = :ets.new(:timex_mock, [:named_table])
    cleanup_dets()
    on_exit fn -> cleanup_dets() end

    {:ok, pid} = Dhcp.Binding.start()

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
    assert Dhcp.Binding.get_offer_address(
      pid, @client_1, req_addr: {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}
  end

  test "ignores requested address if client bound to another address",
    %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.get_offer_address(
      pid, @client_1, req_addr: {192, 168, 0, 5}) ==
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
    assert Dhcp.Binding.get_offer_address(
      pid, @client_1, req_addr: {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end

  test "prefers requested address to previously offered address",
    %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.get_offer_address(
      pid, @client_1, req_addr: {192, 168, 0, 5}) ==
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

  test "offers a shorter lease than max if requested", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, req_lease: 3600) ==
      {:ok, {192, 168, 0, 3}, 3600}
  end

  test "offers the max lease if higher is requested", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, req_lease: 100000) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end

  test "allocates the offered lease", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, req_lease: 3600) ==
      {:ok, {192, 168, 0, 3}, 3600}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 3600}
  end

  test "offers the remaining lease time to a bound client", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, req_lease: 3600) ==
      {:ok, {192, 168, 0, 3}, 3600}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 3600}
    set_timestamp(1)
    assert Dhcp.Binding.get_offer_address(pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 3599}
  end

  test "accepts extension for a bound client", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, req_lease: 3600) ==
      {:ok, {192, 168, 0, 3}, 3600}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 3600}
    set_timestamp(1800)
    assert Dhcp.Binding.allocate_address(
      pid, @client_1, {192, 168, 0, 3}, 3600) ==
      {:ok, {192, 168, 0, 3}, 3600}
  end

  test "caps extensions to max lease", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, req_lease: 3600) ==
      {:ok, {192, 168, 0, 3}, 3600}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 3600}
    set_timestamp(1800)
    assert Dhcp.Binding.allocate_address(
      pid, @client_1, {192, 168, 0, 3}, 100000) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end

  test "recovers allocated addresses from disk", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(
      pid, @client_1, req_addr: {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}

    set_timestamp(1)
    Dhcp.Binding.stop()
    {:ok, new_pid} = Dhcp.Binding.start()

    assert Dhcp.Binding.get_offer_address(new_pid, @client_1) ==
      {:ok, {192, 168, 0, 5}, 86399}
  end

  test "restarts timer when recovering addresses", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(
      pid, @client_1, req_addr: {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}

    set_timestamp(1)
    Dhcp.Binding.stop()
    {:ok, new_pid} = Dhcp.Binding.start()

    assert Dhcp.Binding.get_offer_address(new_pid, @client_1) ==
      {:ok, {192, 168, 0, 5}, 86399}
    check_timer_start(86399, new_pid, @client_1, {192, 168, 0, 5})
  end

  test "doesn't recover offered addresses from disk", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(
      pid, @client_1, req_addr: {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}

    Dhcp.Binding.stop()
    {:ok, new_pid} = Dhcp.Binding.start()

    assert Dhcp.Binding.get_offer_address(new_pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end

  test "doesn't recover released addresses from disk", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(
      pid, @client_1, req_addr: {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}
    assert Dhcp.Binding.release_address(pid, @client_1, {192, 168, 0, 5}) ==
      :ok

    Dhcp.Binding.stop()
    {:ok, new_pid} = Dhcp.Binding.start()

    assert Dhcp.Binding.get_offer_address(new_pid, @client_1) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end
end

