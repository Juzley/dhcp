defmodule Dhcp.ServerTest do
  use ExUnit.Case, async: false
  alias Dhcp.Server
  alias Dhcp.Packet

  doctest Dhcp.Server

  defp make_client_packet() do
    %Packet{
      options: %{message_type: :discover}
    }
  end

  test "responds to a discover packet" do
    #Server.handle_info({:udp, nil, nil, 67}
    #Dhcp.Server.handle_discover(0, %{socket: 0})
    #receive do
    #  {socket, ip, port, data} -> assert true
    #after
    #  50 -> assert false
    #end
  end
end
