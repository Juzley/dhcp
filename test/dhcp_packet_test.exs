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

    test "frames an offer packet" do
      packet = %Dhcp.Packet{
        op: 2,
        xid: 15645,
        ciaddr: {0, 0, 0, 0},
        yiaddr: {192, 168, 0, 10},
        siaddr: {192, 168, 0, 1},
        giaddr: {0, 0, 0, 0},
        chaddr: {0, 11, 130, 1, 252, 66},
        options: %{
          53 => 2,
          1  => {255, 255, 255, 0},
          58 => 1800,
          59 => 3150,
          51 => 3600,
          54 => {192, 168, 0, 1}
        }
      }
      framed = Dhcp.Packet.frame({0x00, 0x08, 0x74, 0xad, 0xf1, 0x9b},
                                 {0x00, 0x0b, 0x82, 0x01, 0xfc, 0x42},
                                 {192, 168, 0, 1},
                                 {192, 168, 0, 10},
                                 packet)

      # TODO: Check header values.

    end
end
