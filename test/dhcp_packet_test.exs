defmodule Dhcp.Test.Packet do
    use ExUnit.Case
    import Dhcp.Test.Packets
    require Record

    # Import packet header records from the pkt erlang module.
    Record.defrecord :ether, Record.extract(
      :ether, from: "deps/pkt/include/pkt.hrl")
    Record.defrecord :ipv4, Record.extract(
      :ipv4, from: "deps/pkt/include/pkt.hrl")
    Record.defrecord :udp, Record.extract(
      :udp, from: "deps/pkt/include/pkt.hrl")

    test "parses a discover packet" do
      assert Dhcp.Packet.parse(discover_packet()) ==
        {:ok, %Dhcp.Packet{op: :request,
                           xid: 15645,
                           ciaddr: {0, 0, 0, 0},
                           yiaddr: {0, 0, 0, 0},
                           siaddr: {0, 0, 0, 0},
                           giaddr: {0, 0, 0, 0},
                           chaddr: {0, 11, 130, 1, 252, 66},
                           options: %{:requested_address => {0, 0, 0, 0},
                                      :message_type => :discover,
                                      :client_id => {0, 11, 130, 1, 252, 66}}}}
    end

    test "parses a request packet" do
      assert Dhcp.Packet.parse(request_packet()) ==
        {:ok, %Dhcp.Packet{op: :request,
                           xid: 15646,
                           ciaddr: {0, 0, 0, 0},
                           yiaddr: {0, 0, 0, 0},
                           siaddr: {0, 0, 0, 0},
                           giaddr: {0, 0, 0, 0},
                           chaddr: {0, 11, 130, 1, 252, 66},
                           options: %{:requested_address => {192, 168, 0, 10},
                                      :message_type => :request,
                                      :server_address => {192, 168, 0, 1},
                                      :client_id => {0, 11, 130, 1, 252, 66}}}}
    end

    test "frames an offer packet" do
      packet = %Dhcp.Packet{
        op: :reply,
        xid: 15645,
        ciaddr: {0, 0, 0, 0},
        yiaddr: {192, 168, 0, 10},
        siaddr: {192, 168, 0, 1},
        giaddr: {0, 0, 0, 0},
        chaddr: {0, 11, 130, 1, 252, 66},
        options: %{
          :message_type   => :offer,
          :subnet_mask    => {255, 255, 255, 0},
          :renewal_time   => 1800,
          :rebinding_time => 3150,
          :lease_time     => 3600,
          :server_address => {192, 168, 0, 1}
        }
      }
      framed = Dhcp.Packet.frame({0x00, 0x08, 0x74, 0xad, 0xf1, 0x9b},
                                 {0x00, 0x0b, 0x82, 0x01, 0xfc, 0x42},
                                 {192, 168, 0, 1},
                                 {192, 168, 0, 10},
                                 packet)

      # Check that the various network headers match expectations.
      assert {:ok, {[eth_hdr, ip_hdr, udp_hdr], _payload}} =
        :pkt.decode(framed)
      assert ether(shost: <<0x00, 0x08, 0x74, 0xad, 0xf1, 0x9b>>,
                   dhost: <<0x00, 0x0b, 0x82, 0x01, 0xfc, 0x42>>,
                   type: 0x800) = eth_hdr
      assert udp(sport: 67, dport: 68, ulen: _, sum: _) = udp_hdr
      assert ipv4(v: 4, hl: _, tos: _, len: _, id: _, df: _, mf: _, off: _,
                  ttl: _, p: 17, sum: _, opt: _,
                  saddr: {192, 168, 0, 1},
                  daddr: {192, 168, 0, 10}) = ip_hdr

      # Check that the DHCP payload is correct - we do this by parsing the
      # framed packet again, as checking against the binary output is tricky
      # due to there being no fixed ordering for DHCP options.
      assert Dhcp.Packet.parse(framed) == {:ok, packet}
    end
end
