defmodule Dhcp.Test.Server do
  use ExUnit.Case, async: false
  alias Dhcp.Server
  alias Dhcp.Packet
  alias Dhcp.Binding

  doctest Dhcp.Server

  @empty_mac  {0, 0, 0, 0, 0, 0}
  @empty_addr {0, 0, 0, 0}
  @client_mac {0, 1, 2, 3, 4, 5}

  defp frame(packet) do
    # We don't care what's in the header, as the server doesn't use it, so
    # just use empty addresses.
    Packet.frame(@empty_mac, @empty_mac, @empty_addr, @empty_addr, packet)
  end

  defp parse(packet) do
    {:ok, parsed} = Packet.parse packet
    parsed
  end

  defp inject(packet, pid) do
    send(pid, {:udp, :dummy_socket, @empty_addr, 67, packet})
  end

  defp cleanup_binding do
    if Enum.find(Process.registered(), fn p -> p == Binding end) do
      Binding.stop()
    end
  end

  defp cleanup_dets do
    try do 
      :dets.delete_all_objects("bindings.dets")
    rescue
      _ -> :ok
    end
  end

  defp cleanup do
    cleanup_binding()
    cleanup_dets()
  end

  setup do
    cleanup()
    on_exit fn -> cleanup() end

    {:ok, _} = Binding.start()
    true = Process.register(self(), :test_process)
    {:ok, pid} = Server.start()

    %{server: pid}
  end

  test "responds to a discover packet", %{server: pid} do
    %Packet{
      op: :request,
      xid: 1,
      chaddr: @client_mac,
      options: %{message_type: :discover,
                 client_id:    @client_mac}
    }
    |> frame
    |> inject(pid)
    
    assert_receive({:packet, sent_packet})

    parsed = parse(sent_packet)
    assert parsed == %Packet{
      op: :reply,
      xid: 1,
      siaddr: {192, 168, 0, 2},
      yiaddr: {192, 168, 0, 3},
      chaddr: @client_mac,
      options: %{message_type:    :offer,
                 server_address:  {192, 168, 0, 2},
                 subnet_mask:     {255, 255, 255, 0},
                 gateway_address: [{192, 168, 0, 1}],
                 dns_address:     [{192, 168, 0, 1}],
                 lease_time:      86400}
    }
  end

  test "acks a valid request packet", %{server: pid} do
    %Packet{
      op: :request,
      xid: 2,
      chaddr: @client_mac,
      options: %{message_type:      :request,
                 client_id:         @client_mac,
                 server_address:    {192, 168, 0, 2},
                 requested_address: {192, 168, 0, 3}}
    }
    |> frame
    |> inject(pid)

    assert_receive({:packet, sent_packet})
    parsed = parse(sent_packet)
    assert parsed == %Packet{
      op: :reply,
      xid: 2,
      siaddr: {192, 168, 0, 2},
      yiaddr: {192, 168, 0, 3},
      chaddr: @client_mac,
      options: %{message_type:    :ack,
                 server_address:  {192, 168, 0, 2},
                 subnet_mask:     {255, 255, 255, 0},
                 gateway_address: [{192, 168, 0, 1}],
                 dns_address:     [{192, 168, 0, 1}],
                 lease_time:      86400}
    }
  end
end
