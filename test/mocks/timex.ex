defmodule Dhcp.Test.Mock.Timex do
  def now do
    try do
      case :ets.lookup(:timex_mock, :timestamp) do
        [timestamp: t] ->
          t

        _ ->
          0
      end
    rescue
      _ -> 0
    end
  end

  def to_unix(t), do: t
end
