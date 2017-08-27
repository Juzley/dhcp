defmodule Dhcp.Packet do
  defstruct [
    :op, :xid, :ciaddr, :yiaddr, :siaddr, :giaddr, :chaddr, options: %{}]

  @cookie 0x63825363

  def frame(packet) do
    options = frame_options(packet.options)

    <<packet.op     :: size(8),
      1             :: size(8),               # Hardware type, Ethernet
      6             :: size(8),               # MAC address length
      0             :: size(8),               # Hops
      packet.xid    :: big-unsigned-size(32),
      0             :: size(8),               # Seconds
      0             :: size(16),              # Flags
      packet.ciaddr :: bitstring-size(32),
      packet.yiaddr :: bitstring-size(32),
      packet.siaddr :: bitstring-size(32),
      packet.giaddr :: bitstring-size(32),
      packet.chaddr :: bitstring-size(48),
      0             :: size(80),              # Hardware address padding
      0             :: size(512),             # Server name (bootp legacy)
      0             :: size(1024),            # Filename (bootp legacy)
      @cookie       :: big-unsigned-size(32), # DHCP magic cookie
      options       :: binary,
      255           :: size(8)>>
  end

  defp frame_options(options) do
    options
    |> Map.to_list
    |> Enum.map(&frame_option/1)
    |> List.foldr(<<>>, fn(option, acc) -> option <> acc end)
  end

  defp frame_option({53, val}), do: <<53::8, 1::8, val::8>>

  defp frame_option({option, val}) when option in [1, 54] do
    <<option :: 8, 4 :: 8, val :: bitstring-size(32)>>
  end

  defp frame_option({option, val}) when option in [51, 58, 59] do
    <<option :: 8, 4 :: 8, val :: big-unsigned-size(32)>>
  end

  def parse(data) do
    try do
      <<_eth_header     :: binary-size(14),
        _v4_header      :: binary-size(20),
        _udp_header     :: binary-size(8),
        op              :: size(8),
        1               :: size(8),               # Hardware type, Ethernet
        6               :: size(8),               # MAC address length
        _hops           :: size(8),
        xid             :: big-unsigned-size(32), # Transaction ID
        _secs           :: big-unsigned-size(16),
        flags           :: bitstring-size(16),
        ciaddr          :: bitstring-size(32),
        yiaddr          :: bitstring-size(32),
        siaddr          :: bitstring-size(32),
        giaddr          :: bitstring-size(32),
        chaddr          :: bitstring-size(48),    # Hardware address
        _chaddr_pad     :: binary-size(10),       # Hardware address padding
        _sname          :: binary-size(64),
        _filename       :: binary-size(128),     
        @cookie         :: big-unsigned-size(32), # DHCP magic cookie
        option_data     :: binary>> = data

        options = parse_options(option_data, %{}) 
        packet = %Dhcp.Packet{
          op: op,
          xid: xid,
          ciaddr: ciaddr,
          yiaddr: yiaddr,
          siaddr: siaddr,
          giaddr: giaddr,
          chaddr: chaddr,
          options: options} 

        {:ok, packet}
    rescue
      MatchError ->
        {:error, :parse_fail}
    end
  end

  # End of packet
  defp parse_options(<<255::8, remainder::binary>>, options), do: options

  # Skip padding bytes
  defp parse_options(<<0::8, remainder::binary>>, options) do
    parse_options(remainder, options)
  end

  # DHCP message type
  defp parse_options(<<53::8, 1::8,
                     dhcp_type::8, remainder::binary>>, options) do
    parse_options remainder, Map.put(options, 53, dhcp_type)
  end

  # Client identifier
  defp parse_options(<<61::8, 7::8, 1::8,
                     mac_addr::bitstring-size(48),
                     remainder::binary>>, options) do
    parse_options remainder, Map.put(options, 61, mac_addr)
  end

  # Skip other option types that we don't support
  defp parse_options(<<option::8, len::8, remainder::binary>>, options) do
    <<value :: binary-size(len), new_remainder :: binary>> = remainder
    parse_options(new_remainder, options)
  end
end
