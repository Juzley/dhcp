defmodule Dhcp.Test.Packet do
    use ExUnit.Case
    import Dhcp.Test.Packets

    test "parses a discover packet" do
      assert Dhcp.Packet.parse(discover_packet()) ==
        {:ok, %Dhcp.Packet{op: 1,
                           xid: 15645,
                           ciaddr: {0, 0, 0, 0},
                           yiaddr: {0, 0, 0, 0},
                           siaddr: {0, 0, 0, 0},
                           giaddr: {0, 0, 0, 0},
                           chaddr: {0, 11, 130, 1, 252, 66},
                           options: %{50 => {0, 0, 0, 0},
                                      53 => 1,
                                      61 => {0, 11, 130, 1, 252, 66}}}}
    end

    test "parses a request packet" do
      assert Dhcp.Packet.parse(request_packet()) ==
        {:ok, %Dhcp.Packet{op: 1,
                           xid: 15646,
                           ciaddr: {0, 0, 0, 0},
                           yiaddr: {0, 0, 0, 0},
                           siaddr: {0, 0, 0, 0},
                           giaddr: {0, 0, 0, 0},
                           chaddr: {0, 11, 130, 1, 252, 66},
                           options: %{50 => {192, 168, 0, 10},
                                      53 => 3,
                                      54 => {192, 168, 0, 1},
                                      61 => {0, 11, 130, 1, 252, 66}}}}
    end
end
