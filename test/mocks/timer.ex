defmodule Dhcp.Test.Timer do
  def apply_after time, _module, _func, args do
    [{_, parent}] = :ets.lookup(:parent_pid, self())
    send(parent, {time, args})

    {:ok, 0}
  end
end
