defmodule Dhcp.Test.Mock.Packet do
  def socket(_protocol), do: {:ok, 0}
  def default_interface, do: "interface"
  def ifindex(_socket, _interface), do: 0

  def send(_socket, _ifindex, packet) do
    send(self(), packet)
    :ok
  end
end
