defmodule Dhcp do
  use Application

  def start(_type, _args) do
    {:ok, _pid} = Dhcp.Server.start()
  end
end
