defmodule Dhcp.Test.Timex do
  def now do
    case :ets.lookup(:timex_mock, :timestamp) do
      [timestamp: t] ->
        t

      _ ->
        0
    end
  end

  def to_unix(t), do: t
end
