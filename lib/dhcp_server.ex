defmodule Dhcp.Server do
  @moduledoc """
    This module implements a GenServer which handles DHCP requests.
  """

  use GenServer
  require Logger

  import Dhcp.Util
  alias Dhcp.Binding
  alias Dhcp.Packet

  @udp Application.get_env(:dhcp, :udp_impl, :gen_udp)
  @packet Application.get_env(:dhcp, :packet_impl, :packet)
  @inet Application.get_env(:dhcp, :inet_impl, :inet)

  @dhcp_server_port 67
  @empty_address {0, 0, 0, 0}
  @broadcast_address {255, 255, 255, 255}
  @broadcast_mac {255, 255, 255, 255, 255, 255}

  @server_address Application.fetch_env!(:dhcp, :server_address)
  @gateway_address Application.fetch_env!(:dhcp, :gateway_address)
  @dns_address Application.fetch_env!(:dhcp, :dns_address)
  @subnet_mask Application.fetch_env!(:dhcp, :subnet_mask)

  # TODO: DHCPInform, DHCPDecline

  # Client API

  def start_link(_state) do
    start()
  end


  def start(_arg \\ :ok) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # Server API

  def init(:ok) do
    result = {:ok, %{}}
             |> init_bcast_rx_socket()
             |> init_ucast_rx_socket()
             |> init_tx_socket()
             |> init_src_mac()

    case result do
      {:error, reason} ->
        {:stop, reason}

      _ ->
        result
    end
  end

  # Initialize the unicast receive socket.
  defp init_ucast_rx_socket({:ok, state}) do
    case result = @udp.open(@dhcp_server_port,
                            [:binary, {:ifaddr, @server_address}]) do
      {:ok, socket} ->
        {:ok, Map.put(state, :ucast_rx_socket, socket)}

      _ ->
        result
    end
  end
  defp init_ucast_rx_socket(err), do: err

  # Initialize the broadcast receive socket.
  defp init_bcast_rx_socket({:ok, state}) do
    case result = @udp.open(@dhcp_server_port,
                            [:binary, {:ifaddr, @broadcast_address}]) do
      {:ok, socket} ->
        {:ok, Map.put(state, :bcast_rx_socket, socket)}

      _ ->
        result
    end
  end
  defp init_bcast_rx_socket(err), do: err

  # Initialize the send socket.
  defp init_tx_socket({:ok, state}) do
    case result = @packet.socket(0x800) do
      {:ok, socket} ->
        intf = @packet.default_interface()
        ifindex = @packet.ifindex(socket, intf)
        {:ok, Map.merge(state, %{tx_socket: socket, ifindex: ifindex})}

      _ ->
        result
    end
  end
  defp init_tx_socket(err), do: err

  # Get the MAC address for the interface we're going to send on.
  defp init_src_mac({:ok, state}) do
    mac_info =
      @packet.default_interface()
      |> List.first
      |> @inet.ifget([:hwaddr])

    case mac_info do
      {:ok, [hwaddr: mac]} ->
        {:ok, Map.put(state, :src_mac, List.to_tuple(mac))}

      _ ->
        {:error, :if_mac_not_found}
    end
  end
  defp init_src_mac(err), do: err

  # UDP packet callback.
  def handle_info({_, _socket}, state), do: {:noreply, state}
  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    case Packet.parse(data) do
      {:ok, packet} ->
        new_state = handle_packet(state, packet)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.debug "Failed to parse packet: #{reason}"
        {:noreply, state}
    end
  end

  # We don't support multiple subnets, relay etc - ignore packets with a
  # non-zero giaddr.
  defp handle_packet(state, %Packet{giaddr: giaddr})
    when giaddr !== @empty_address do
    Logger.error "Ignoring DHCP message with non-zero giaddr"

    state
  end

  # Handle a successfully parsed DHCP packet.
  defp handle_packet(state, packet) do
    case Map.get(packet.options, :message_type, :no_type) do
      :discover ->
        handle_discover(state, packet)

      :request ->
        handle_request(state, packet)

      :release ->
        handle_release(state, packet)

      :no_type ->
        Logger.error "Ignoring DHCP message received with no message type"

      msg_type ->
        Logger.debug "Ignoring DHCP message type #{msg_type}"
    end

    state
  end

  # Handle a discovery packet.
  defp handle_discover(state, packet) do
    req_addr = Map.get(packet.options, :requested_address)
    req_lease = Map.get(packet.options, :lease_time, 0)
    Logger.info(
      "Received Discover message from #{mac_to_string(packet.chaddr)}," <>
      " requested address #{ipv4_to_string(req_addr)}, " <>
      " requested lease #{req_lease}") 

    offer_info = Binding.get_offer_address(Dhcp.Binding,
                                           packet.chaddr,
                                           req_addr: req_addr,
                                           req_lease: req_lease)
    case offer_info do
      {:ok, offer_address, offer_lease} ->
        Logger.info(
          "Offering #{ipv4_to_string(offer_address)} to" <>
          " #{mac_to_string(packet.chaddr)} for #{offer_lease} seconds")
        frame_offer(packet, offer_address, offer_lease, state)
        |> send_response(state)

      {:error, reason} ->
        Logger.error(
          "Failed to get offer address for #{mac_to_string(packet.chaddr)}:" <>
          " #{reason}")
	end
  end

  # Handle a request packet.
  defp handle_request(state, packet) do
    requested_address = Map.get(packet.options, :requested_address)
    server_address = Map.get(packet.options, :server_address)

    Logger.info(
      "Received Request message from #{mac_to_string(packet.chaddr)}" <>
      " to #{ipv4_to_string(server_address)}, requested address" <>
      " #{ipv4_to_string(requested_address)}")

    if server_address == @server_address do
      result = Binding.allocate_address(Dhcp.Binding,
                                        packet.chaddr,
                                        requested_address)
      case result do
        {:ok, addr, lease} ->
          Logger.info(
            "Allocated #{ipv4_to_string(requested_address)} to" <>
            " #{mac_to_string(packet.chaddr)} for #{lease} seconds," <>
            " sending Ack")
          frame_ack(packet, addr, lease, state) |> send_response(state)

        {:error, reason} ->
          Logger.error(
            "Failed to allocate #{ipv4_to_string(requested_address)} to" <>
            " #{mac_to_string(packet.chaddr)}: #{reason}, sending Nak")
          frame_nak(packet, state) |> send_response(state)
      end
    else
      # Forget any offers etc if the request is for a different server.
      Binding.cancel_offer(Dhcp.Binding,
                           packet.chaddr)
    end
  end

  # Handle a release packet.
  defp handle_release(_state, packet) do
    server_address = Map.get(packet.options, 54)
    Logger.info(
      "Received Release message from #{mac_to_string(packet.chaddr)} to" <>
      " #{ipv4_to_string(server_address)}, released address" <>
      " #{ipv4_to_string(packet.ciaddr)}")

    if server_address == @server_address do
      result = Binding.release_address(Dhcp.Binding,
                                       packet.chaddr,
                                       packet.ciaddr)
      case result do
        :ok ->
          Logger.info(
            "Released #{ipv4_to_string(packet.ciaddr)} from" <>
            " #{mac_to_string(packet.chaddr)}")

        {:error, reason} ->
          Logger.error(
            "Failed to release #{ipv4_to_string(packet.ciaddr)} from" <>
            " #{mac_to_string(packet.chaddr)}: #{reason}")
        end
    end
  end

  # Frame a DHCPOFFER
  defp frame_offer(req_packet, offer_addr, offer_lease, state) do
    {dst_mac, dst_addr} = reply_addrs(
      req_packet.broadcast_flag, req_packet.ciaddr, req_packet.chaddr,
      offer_addr)
    Packet.frame(
      state.src_mac,
      dst_mac,
      @server_address,
      dst_addr,
      %Packet{
        op: :reply,
        xid: req_packet.xid,
        ciaddr: @empty_address,
        yiaddr: offer_addr,
        giaddr: req_packet.giaddr,
        chaddr: req_packet.chaddr,
        options: %{ :message_type    => :offer,
                    :subnet_mask     => @subnet_mask,
                    :gateway_address => [@gateway_address],
                    :dns_address     => [@dns_address],
                    :lease_time      => offer_lease,
                    :server_address  => @server_address
        }
      }
    )
  end

  # Frame a DHCPACK
  defp frame_ack(req_packet, addr, lease, state) do
    {dst_mac, dst_addr} = reply_addrs(
      req_packet.broadcast_flag, req_packet.ciaddr, req_packet.chaddr, addr)
    Packet.frame(
      state.src_mac,
      dst_mac,
      @server_address,
      dst_addr,
      %Packet{
        op: :reply,
        xid: req_packet.xid,
        ciaddr: @empty_address,
        yiaddr: addr,
        giaddr: req_packet.giaddr,
        chaddr: req_packet.chaddr,
        options: %{ :message_type     => :ack,
                    :subnet_mask      => @subnet_mask,
                    :gateway_address  => [@gateway_address],
                    :dns_address      => [@dns_address],
                    :lease_time       => lease,
                    :server_address   => @server_address
        }
      }
    )
  end

  # Frame a DHCPNAK
  defp frame_nak(req_packet, state) do
    Packet.frame(
      state.src_mac,
      @broadcast_mac,
      @server_address,
      @broadcast_address,
      %Packet{ op: :reply,
         xid: req_packet.xid,
         ciaddr: @empty_address,
         yiaddr: @empty_address,
         siaddr: @empty_address,
         giaddr: @empty_address,
         chaddr: req_packet.chaddr,
         options: %{message_type:   :nak,
                    server_address: @server_address
         }
      })
  end

  # Send a framed response to a client.
  defp send_response(packet, state) do
    :ok = @packet.send(state.tx_socket, state.ifindex, packet)
  end

  # Return addresses to send offer/acks to. Note that we ignore the giaddr
  # field, we don't support different subnets.
  # In this clause, the address isn't already allocated, and the client has
  # requested a broadcast.
  defp reply_addrs(_bcast=true, _ciaddr=@empty_address, _chaddr, _addr) do
    {@broadcast_mac, @broadcast_address}
  end

  # In this clause, the address isn't already allocated, and the client does
  # not require the response to be broadcast.
  defp reply_addrs(_bcast=false, _ciaddr=@empty_address, chaddr, addr) do
    {chaddr, addr}
  end

  # In this clause, the address is already allocated, so we can respond to it.
  defp reply_addrs(_broadcast, ciaddr, chaddr, _addr) do
    {chaddr, ciaddr}
  end
end
