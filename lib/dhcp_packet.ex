defmodule Dhcp.Packet do
  require Record
  require Logger
  use Bitwise

  # TODO: Parse requested options field.

  # Struture representing a DHCP packet.
  defstruct [
    op: 0, xid: 0, ciaddr: {0, 0, 0, 0}, yiaddr: {0, 0, 0, 0},
    siaddr: {0, 0, 0, 0}, giaddr: {0, 0, 0, 0}, chaddr: {0, 0, 0, 0, 0, 0},
    broadcast_flag: false, options: %{}]

  # Import IPv4 and UDP header records from the pkt erlang module.
  Record.defrecord :ipv4, Record.extract(
    :ipv4, from: "deps/pkt/include/pkt.hrl")
  Record.defrecord :udp, Record.extract(
    :udp, from: "deps/pkt/include/pkt.hrl")

  # DHCP Magic Cookie
  @cookie 0x63825363

  @ doc """
  Frame a DHCP packet, adding Ethernet and UDP headers.
  """
  def frame(src_mac, dst_mac, src_ip, dst_ip, packet) do
    op = convert_op(packet.op)
    options = frame_options(packet.options)
    ciaddr = ipv4_tuple_to_binary(packet.ciaddr)
    yiaddr = ipv4_tuple_to_binary(packet.yiaddr)
    siaddr = ipv4_tuple_to_binary(packet.siaddr)
    giaddr = ipv4_tuple_to_binary(packet.giaddr)
    chaddr = mac_tuple_to_binary(packet.chaddr)
    flags = if packet.broadcast_flag, do: 1 <<< 15, else: 0

    <<op         :: size(8),
      1          :: size(8),               # Hardware type, Ethernet
      6          :: size(8),               # MAC address length
      0          :: size(8),               # Hops
      packet.xid :: big-unsigned-size(32),
      0          :: size(16),              # Seconds
      flags      :: size(16),              # Flags
      ciaddr     :: bitstring-size(32),
      yiaddr     :: bitstring-size(32),
      siaddr     :: bitstring-size(32),
      giaddr     :: bitstring-size(32),
      chaddr     :: bitstring-size(48),
      0          :: size(80),              # Hardware address padding
      0          :: size(512),             # Server name (bootp legacy)
      0          :: size(1024),            # Filename (bootp legacy)
      @cookie    :: big-unsigned-size(32), # DHCP magic cookie
      options    :: binary,
      255        :: size(8)>>
    |> frame_udpip(src_ip, dst_ip)
    |> frame_ether(src_mac, dst_mac)
  end

  # Frame a list of DHCP options.
  defp frame_options(options) do
    options
    |> Map.to_list
    |> Enum.map(&frame_option/1)
    |> List.foldr(<<>>, fn(option, acc) -> option <> acc end)
  end

  # Frame the message type option.
  defp frame_option({:message_type, val}) do
    <<53::8, 1::8, convert_message_type(val)::8>>
  end

  # Frame options with a list of IPv4 addresses.
  defp frame_option({option, addrs})
    when option in [:gateway_address, :dns_address] do
    enc = addrs
          |> Enum.map(&ipv4_tuple_to_binary/1)
          |> Enum.reduce(fn(r, acc) -> r <> acc end)
    len = 4 * length(addrs)
    <<convert_option(option)::8, len::8, enc::binary>>
  end

  # Frame options with a single IPv4 address.
  defp frame_option({option, addr})
    when option in [:subnet_mask, :server_address, :requested_address] do
    enc = ipv4_tuple_to_binary(addr)
    <<convert_option(option)::8, 4::8, enc::bitstring-size(32)>>
  end

  # Frame options with a single 4-byte value.
  defp frame_option({option, val})
    when option in [:lease_time, :renewal_time, :rebinding_time] do
    <<convert_option(option)::8, 4::8, val::big-unsigned-size(32)>>
  end

  # Frame a client ID.
  defp frame_option({option=:client_id, mac}) do
    enc = mac_tuple_to_binary(mac)
    <<convert_option(option)::8, 6::8, enc::bitstring-size(48)>>
  end

  # Stick an Ethernet header on the front of a packet.
  defp frame_ether(payload, src_mac, dst_mac) do
    mac_tuple_to_binary(dst_mac) <> mac_tuple_to_binary(src_mac) <>
      <<0x0800::16>> <> payload
  end

  # Stick a UDP header on the front of a packet.
  defp frame_udpip(payload, src_addr, dst_addr) do
    udp_len = byte_size(payload) + 8
    ipv4_len = udp_len + 20
    ipv4_info = ipv4(saddr: src_addr, daddr: dst_addr, len: ipv4_len, p: 17)
    udp_info = udp(sport: 67, dport: 68, ulen: udp_len)
    ipv4_sum = :pkt.makesum([ipv4_info, udp_info, payload])

    :pkt.ipv4(ipv4(ipv4_info, sum: ipv4_sum)) <> :pkt.udp(udp_info) <> payload 
  end

  @doc """
  Parse a DHCP packet, including the Ethernet and UDP headers.
  """
  def parse(packet=<<_eth_header     :: binary-size(14),
                     _v4_header      :: binary-size(20),
                     _udp_header     :: binary-size(8),
                     _op             :: size(8),
                     1               :: size(8),
                     6               :: size(8),
                     _hops           :: size(8),
                     _xid            :: big-unsigned-size(32),
                     _secs           :: big-unsigned-size(16),
                     _broadcast      :: big-unsigned-size(1),
                     _flags          :: bitstring-size(15),
                     _ciaddr         :: bitstring-size(32),
                     _yiaddr         :: bitstring-size(32),
                     _siaddr         :: bitstring-size(32),
                     _giaddr         :: bitstring-size(32),
                     _chaddr         :: bitstring-size(48),
                     _chaddr_pad     :: binary-size(10),
                     _sname          :: binary-size(64),
                     _filename       :: binary-size(128),
                     @cookie         :: big-unsigned-size(32),
                     _options        :: binary>>) do
    <<_headers::binary-size(42), payload::binary>> = packet
    parse(payload)
  end

  @doc """
  Parse a DHCP packet, without Ethernet or UDP headers.
  """
  def parse(<<op              :: size(8),
              1               :: size(8),               # Hardware type
              6               :: size(8),               # MAC address length
              _hops           :: size(8),
              xid             :: big-unsigned-size(32), # Transaction ID
              _secs           :: big-unsigned-size(16),
              broadcast       :: big-unsigned-size(1),
              _flags          :: bitstring-size(15),
              ciaddr          :: bitstring-size(32),
              yiaddr          :: bitstring-size(32),
              siaddr          :: bitstring-size(32),
              giaddr          :: bitstring-size(32),
              chaddr          :: bitstring-size(48),    # Hardware address
              _chaddr_pad     :: binary-size(10),       # Hardware address pad
              _sname          :: binary-size(64),
              _filename       :: binary-size(128),
              @cookie         :: big-unsigned-size(32), # DHCP magic cookie
              options         :: binary>>) do
    options = parse_options(options, %{})
    packet = %Dhcp.Packet{
      op: convert_op(op),
      xid: xid,
      ciaddr: ipv4_binary_to_tuple(ciaddr),
      yiaddr: ipv4_binary_to_tuple(yiaddr),
      siaddr: ipv4_binary_to_tuple(siaddr),
      giaddr: ipv4_binary_to_tuple(giaddr),
      chaddr: mac_binary_to_tuple(chaddr),
      broadcast_flag: broadcast == 1,
      options: options
    }

    {:ok, packet}
  end

  # The packet isn't a valid DHCP packet, return an error.
  def parse(_) do
    {:error, :bad_packet}
  end

  # End of packet
  defp parse_options(<<255::8, _remainder::binary>>, options), do: options

  # Skip padding bytes
  defp parse_options(<<0::8, remainder::binary>>, options) do
    parse_options(remainder, options)
  end

  # DHCP message type
  defp parse_options(<<53::8, 1::8,
                     dhcp_type::8, remainder::binary>>, options) do
    new_options = Map.put(options,
                          :message_type,
                          convert_message_type(dhcp_type))
    parse_options(remainder, new_options)
  end

  # Client identifier
  defp parse_options(<<61::8, 7::8, 1::8,
                     mac_addr::bitstring-size(48),
                     remainder::binary>>, options) do
    parse_options remainder, Map.put(options,
                                     :client_id,
                                     mac_binary_to_tuple(mac_addr))
  end

  # Values represented by a single IPv4 addr.
  defp parse_options(
    <<option::8, 4::8, addr::bitstring-size(32),
      remainder::binary>>, options) when option in [1, 50, 54] do
    parse_options remainder, Map.put(options,
                                     convert_option(option),
                                     ipv4_binary_to_tuple(addr))
  end

  # Values represented by several IPv4 addresses.
  defp parse_options(
    <<option::8, len::8, tail::binary>>, options) when option in [3, 6] do
    <<addrs :: binary-size(len), remainder :: binary>> = tail
    addr_list =
      for <<addr :: binary-size(4) <- addrs>>, do: ipv4_binary_to_tuple(addr)
    parse_options remainder, Map.put(options,
                                     convert_option(option),
                                     addr_list)
  end

  # Other 4-byte values, such as lease times.
  defp parse_options(
    <<option::8, 4::8, value::big-unsigned-size(32),
      remainder::binary>>, options) when option in [51, 58, 59] do
    parse_options remainder, Map.put(options, convert_option(option), value)
  end

  # Skip other option types that we don't support
  defp parse_options(<<_option::8, len::8, tail::binary>>, options) do
    <<_value :: binary-size(len), remainder :: binary>> = tail
    parse_options(remainder, options)
  end

  # Stop parsing options if we don't recognize the format.
  defp parse_options(_, options), do: options

  # Convert an IPv4 in binary form to a tuple.
  defp ipv4_binary_to_tuple <<oct4::8, oct3::8, oct2::8, oct1::8>> do
    {oct4, oct3, oct2, oct1}
  end

  # Convert an IPv4 in tuple form to binary.
  defp ipv4_tuple_to_binary {oct4, oct3, oct2, oct1} do
    <<oct4::8, oct3::8, oct2::8, oct1::8>>
  end

  # Convert a MAC in binary form to a tuple.
  defp mac_binary_to_tuple <<oct6::8, oct5::8, oct4::8, oct3::8, oct2::8, oct1::8>> do
    {oct6, oct5, oct4, oct3, oct2, oct1}
  end

  # Convert a MAC in tuple form to binary.
  defp mac_tuple_to_binary {oct6, oct5, oct4, oct3, oct2, oct1} do
    <<oct6::8, oct5::8, oct4::8, oct3::8, oct2::8, oct1::8>>
  end

  # Convert Bootp op types between numerical and atom forms.
  defp convert_op(op) when is_number(op) do
    case op do
      1 -> :request
      2 -> :reply
    end
  end
  defp convert_op(op) when is_atom(op) do
    case op do
      :request -> 1
      :reply   -> 2
    end
  end

  # Convert DHCP message types between numerical and atom forms.
  defp convert_message_type(type) when is_number(type) do
    case type do
      1 -> :discover
      2 -> :offer
      3 -> :request
      5 -> :ack
      6 -> :nak
      7 -> :release
    end
  end
  defp convert_message_type(type) when is_atom(type) do
    case type do
      :discover -> 1
      :offer -> 2
      :request -> 3
      :ack -> 5
      :nak -> 6
      :release -> 7
    end
  end

  # Convert DHCP option types between numerical and atom forms.
  defp convert_option(type) when is_number(type) do
    case type do
      1  -> :subnet_mask
      3  -> :gateway_address
      6  -> :dns_address
      50 -> :requested_address
      51 -> :lease_time
      54 -> :server_address
      58 -> :renewal_time
      59 -> :rebinding_time
      61 -> :client_id
      _  -> type
    end
  end
  defp convert_option(type) when is_atom(type) do
    case type do
      :subnet_mask       -> 1
      :gateway_address   -> 3
      :dns_address       -> 6
      :requested_address -> 50
      :lease_time        -> 51
      :server_address    -> 54
      :renewal_time      -> 58
      :rebinding_time    -> 59
      :client_id         -> 61
    end
  end
end
