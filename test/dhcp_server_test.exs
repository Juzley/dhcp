defmodule Dhcp.ServerTest do
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

  defp inject(pid, packet) do
    send(pid, {:udp, :dummy_socket, @empty_addr, 67, packet})
  end

  setup_all do
    {:ok, _pid} = Binding.start()
    :ok
  end

  setup do
    true = Process.register(self(), :test_process)
    {:ok, pid} = Server.start()
    %{server: pid}
  end

  test "responds to a discover packet", %{server: pid} do
    packet = %Packet{
      op: :request,
      xid: 1,
      chaddr: @client_mac,
      options: %{message_type: :discover,
                 client_id:    @client_mac}
    }
    framed = frame(packet)
    inject(pid, framed)
    assert_received({:packet, sent_packet})
    IO.puts sent_packet
  end
end
