defmodule Dhcp.Test.Mock.GenUDP do
  def open _port, _options \\ [] do
    {:ok, :dummy_socket}
  end
end

