defmodule Dhcp.Packet do
  defstruct [:op, options: %{}]

  def parse(data) do
    try do
      <<_eth_header     :: binary-size(14),
        _v4_header      :: binary-size(20),
        _udp_header     :: binary-size(8),
        op              :: size(8),
        1               :: size(8),               # Hardware type, Ethernet
        6               :: size(8),               # Hardware address length, MAC
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
        0x63825363      :: big-unsigned-size(32), # DHCP magic cookie
        option_data     :: binary>> = data

        options = parse_options(option_data, %{}) 
        packet = %Dhcp.Packet{op: op, options: options} 

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
