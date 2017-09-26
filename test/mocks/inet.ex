defmodule Dhcp.Test.Mock.Inet do
  def ifget(_if, _attrs) do
    {:ok, [hwaddr: [0, 1, 2, 3, 4, 5]]}
  end
end
