defmodule Dhcp do
  use Application

  def start(_type, _args) do
    {:ok, _pid} = Supervisor.start_link([
      {Dhcp.Server, [:ok]},
      {Dhcp.Bindings, [:ok]}
    ], strategy: :one_for_one)
  end
end
