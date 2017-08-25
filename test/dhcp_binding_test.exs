defmodule Dhcp.Test.Binding do
  use ExUnit.Case, async: false

  @server_address {192, 168, 0, 2}
  @gateway_address {192, 168, 0, 1}
  @client_1 {11, 22, 33, 44, 55, 66}
  @client_2 {22, 33, 44, 55, 66, 77}

  defp check_timer_start time, pid, mac, addr do
    receive do
      {msg_time, args} ->
        assert msg_time == time
        assert args == [pid, mac, addr]
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
                                    {192, 168, 0, 5})
    :ets.insert(:parent_pid, {pid, self()})
    on_exit fn -> :ets.delete(:parent_pid, pid) end

    %{bindings: pid}
  end

  test "offers free address", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, nil) ==
      {:ok, {192, 168, 0, 3}}
  end

  test "offers same address for duplicate discovers", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, nil) ==
      {:ok, {192, 168, 0, 3}}
    assert Dhcp.Binding.get_offer_address(pid, @client_1, nil) ==
      {:ok, {192, 168, 0, 3}}
  end

  test "prefers offering an address that hasn't been offered",
       %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, nil) ==
      {:ok, {192, 168, 0, 3}}
    assert Dhcp.Binding.get_offer_address(pid, @client_2, nil) ==
      {:ok, {192, 168, 0, 4}}
  end

  test "successfully allocates an offered address", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, nil) ==
      {:ok, {192, 168, 0, 3}}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      :ok
    check_timer_start(86400, pid, @client_1, {192, 168, 0, 3})
  end

  test "offers the bound address", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, nil) ==
      {:ok, {192, 168, 0, 3}}
    assert Dhcp.Binding.allocate_address(pid, @client_1, {192, 168, 0, 3}) ==
      :ok
    check_timer_start(86400, pid, @client_1, {192, 168, 0, 3})
    assert Dhcp.Binding.get_offer_address(pid, @client_1, nil) ==
      {:ok, {192, 168, 0, 3}}
  end
end

