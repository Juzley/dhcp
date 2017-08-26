defmodule Dhcp.Test.GenUDP do
  def open _port do
    {:ok, :dummy_socket}
  end

  def send socket, ip, port, data do
    send(self(), {socket, ip, port, data})
    :ok
  end
end

