defmodule Dhcp.Test.Binding do
  use ExUnit.Case, async: false

  @server_address <<192::8, 168::8, 0::8, 1::8>>
  @gateway_address <<192::8, 168::8, 0::8, 2::8>>
  @client_mac <<11::8, 22::8, 33::8, 44::8, 55::8, 66::8>>

  setup_all do
    {:ok, pid} = Dhcp.Binding.start(@server_address, @gateway_address)
    %{bindings: pid}
  end

  test "offers a free address", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_mac, nil) ==
      {:ok, <<192::8, 168::8, 0::8, 3::8>>}
  end

  test "offers an address that hasn't been offered", %{bindings: pid} do
    assert Dhcp.Binding.get_offer_address(pid, @client_mac, nil) ==
      {:ok, <<192::8, 168::8, 0::8, 4::8>>}
  end
end
