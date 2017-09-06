defmodule Dhcp.Util do
  def mac_to_string(mac) do
    mac
    |> Tuple.to_list
    |> Enum.map(fn(int) -> Integer.to_string(int, 16) end)
    |> Enum.join(":")
  end

  def ipv4_to_string(nil), do: "<None>"
  def ipv4_to_string(addr) do
    addr
    |> Tuple.to_list
    |> Enum.map(&Integer.to_string/1)
    |> Enum.join(".")
  end
end
