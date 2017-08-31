defmodule Dhcp.Test.Timer do
  def apply_after time, _module, _func, args do
    [{_, parent}] = :ets.lookup(:parent_pid, self())
    send(parent, {:timer_start, time, args})

    # Return the args as a timer ref, this allows us to check in the test
    # that the correct timer was cancelled
    {:ok, args}
  end

  def cancel timer_ref do
    [{_, parent}] = :ets.lookup(:parent_pid, self())
    send(parent, {:timer_cancel, timer_ref})

    {:ok, :cancel}
  end
end
