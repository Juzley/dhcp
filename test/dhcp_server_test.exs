defmodule Dhcp.Test.Server do
  use ExUnit.Case, async: false
  alias Dhcp.Server
  alias Dhcp.Packet
  alias Dhcp.Binding

  doctest Dhcp.Server

  @empty_mac   {0, 0, 0, 0, 0, 0}
  @empty_addr  {0, 0, 0, 0}
  @client_mac1 {0, 1, 2, 3, 4, 5}
  @client_mac2 {0, 1, 2, 3, 4, 6}
  @client_mac3 {0, 1, 2, 3, 4, 7}
  @client_mac4 {0, 1, 2, 3, 4, 8}


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

    true = Process.register(self(), :test_process)

    {:ok, bindings_pid} = Binding.start()
    {:ok, server_pid} = Server.start()

    %{server: server_pid, bindings: bindings_pid}
  end

  test "responds to a discover packet", %{server: pid} do
    %Packet{
      op: :request,
      xid: 1,
      chaddr: @client_mac1,
      options: %{message_type: :discover,
                 client_id:    @client_mac1}
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
      chaddr: @client_mac1,
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
      chaddr: @client_mac1,
      options: %{message_type:      :request,
                 client_id:         @client_mac1,
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
      chaddr: @client_mac1,
      options: %{message_type:    :ack,
                 server_address:  {192, 168, 0, 2},
                 subnet_mask:     {255, 255, 255, 0},
                 gateway_address: [{192, 168, 0, 1}],
                 dns_address:     [{192, 168, 0, 1}],
                 lease_time:      86400}
    }
  end

  test "doesn't offer when no free addresses",
    %{server: server_pid, bindings: bindings_pid} do
    assert Dhcp.Binding.allocate_address(
      bindings_pid, @client_mac1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
    assert Dhcp.Binding.allocate_address(
      bindings_pid, @client_mac2, {192, 168, 0, 4}) ==
      {:ok, {192, 168, 0, 4}, 86400}
    assert Dhcp.Binding.allocate_address(
      bindings_pid, @client_mac3, {192, 168, 0, 5}) ==
      {:ok, {192, 168, 0, 5}, 86400}

    %Packet{
      op: :request,
      xid: 1,
      chaddr: @client_mac4,
      options: %{message_type: :discover,
                 client_id:    @client_mac4}
    }
    |> frame
    |> inject(server_pid)

    refute_receive({:packet, _packet})
  end

  test "naks a request for an in-use address",
    %{server: server_pid, bindings: bindings_pid} do
    assert Dhcp.Binding.allocate_address(
      bindings_pid, @client_mac1, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}

    %Packet{
      op: :request,
      xid: 3,
      chaddr: @client_mac2,
      options: %{message_type:      :request,
                 client_id:         @client_mac2,
                 server_address:    {192, 168, 0, 2},
                 requested_address: {192, 168, 0, 3}}
    }
    |> frame
    |> inject(server_pid)

    assert_receive({:packet, sent_packet})
    parsed = parse(sent_packet)
    assert parsed == %Packet{
      op: :reply,
      xid: 3,
      chaddr: @client_mac2,
      options: %{message_type: :nak,
                 server_address: {192, 168, 0, 2}}
    }
  end

  test "ignores a request to another server",
    %{server: server_pid, bindings: bindings_pid} do

    %Packet{
      op: :request,
      xid: 2,
      chaddr: @client_mac1,
      options: %{message_type:      :request,
                 client_id:         @client_mac1,
                 server_address:    {192, 168, 0, 255},
                 requested_address: {192, 168, 0, 3}}
    }
    |> frame
    |> inject(server_pid)

    refute_receive({:packet, _packet})

    # Check that we didn't allocate the address
    assert Dhcp.Binding.allocate_address(
      bindings_pid, @client_mac2, {192, 168, 0, 3}) ==
      {:ok, {192, 168, 0, 3}, 86400}
  end

end
