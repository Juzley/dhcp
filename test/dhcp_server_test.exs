defmodule Dhcp.ServerTest do
  use ExUnit.Case, async: false

  doctest Dhcp.Server

  test "responds to a discover packet" do
    Dhcp.Server.handle_discover(0, %{socket: 0})
    receive do
      {socket, ip, port, data} -> assert true
    after
      50 -> assert false
    end
  end
end
