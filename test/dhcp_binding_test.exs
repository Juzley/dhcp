defmodule Dhcp.Test.Binding do
  use ExUnit.Case, async: false

  @server_address {192, 168, 0, 2}
  @gateway_address {192, 168, 0, 1}
  @client_1 {11, 22, 33, 44, 55, 66}
  @client_2 {22, 33, 44, 55, 66, 77}

  setup_all do
    {:ok, pid} = Dhcp.Binding.start(@server_address,
                                    @gateway_address,
                                    {192, 168, 0, 1},
                                    {192, 168, 0, 5})
    %{bindings: pid}
  end

  test "dhcp bindings", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_1, nil) ==
      {:ok, {192, 168, 0, 3}}
    assert Dhcp.Binding.get_offer_address(pid, @client_1, nil) ==
      {:ok, {192, 168, 0, 3}}
    assert Dhcp.Binding.get_offer_address(pid, @client_2, nil) ==
      {:ok, {192, 168, 0, 4}}
  end
end

