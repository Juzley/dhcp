defmodule Dhcp.Server do
  use GenServer
  require Logger

  # Client API

  def start do
    GenServer.start_link(__MODULE__, :ok)
  end

  # Server API

  def init(:ok) do
    case :gen_udp.open(67) do
      {:ok, socket} ->
        {:ok, %{socket: socket}}
      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_info({_, _socket}, state), do: {:noreply, state}
  def handle_info({:udp, socket, ip, _port, data}, state) do
    case Dhcp.Packet.parse(data) do
      {:ok, packet} ->
        new_state = handle_packet(packet, state)
        {:noreply, new_state}

      {:error, reason} ->
        {:noreply, state}
    end
  end

  defp handle_packet(packet, state) do
    case Map.get(packet.options, 53) do
      1 ->
        handle_discover(packet, state)

      msg_type ->
        Logger.debug "Ignoring DHCP message type #{msg_type}"
    end

    state
  end

  defp handle_discover(packet, state) do
    :gen_udp.send(state.socket, {255, 255, 255, 255}, 68, "jkl")

    state
  end
end
