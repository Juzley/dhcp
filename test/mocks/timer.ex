defmodule Dhcp.Test.Timer do
  def apply_after time, module, func, args do
    send(self(), {time, args})
    {:ok, 0}
  end
end
