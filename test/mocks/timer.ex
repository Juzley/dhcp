defmodule Dhcp.Test.Mock.Timer do
  def apply_after time, _module, _func, args do
    try do
      send(:test_process, {:timer_start, time, args})
    rescue
      _ -> :ok
    end

    # Return the args as a timer ref, this allows us to check in the test
    # that the correct timer was cancelled
    {:ok, args}
  end

  def cancel timer_ref do
    try do
      send(:test_process, {:timer_cancel, timer_ref})
    rescue
      _ -> :ok
    end

    {:ok, :cancel}
  end
end
