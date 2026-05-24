defmodule CodexPoolerWeb.Plugs.ForwardedSSL do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2]

  @spec websocket_over_forwarded_ssl?(Plug.Conn.t()) :: boolean()
  def websocket_over_forwarded_ssl?(conn) do
    forwarded_proto?(conn, "wss") && websocket_upgrade?(conn)
  end

  defp forwarded_proto?(conn, expected) do
    conn
    |> get_req_header("x-forwarded-proto")
    |> Enum.any?(fn value ->
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.any?(&(String.downcase(&1) == expected))
    end)
  end

  defp websocket_upgrade?(conn) do
    connection_upgrade?(conn) && websocket_header?(conn)
  end

  defp connection_upgrade?(conn) do
    conn
    |> get_req_header("connection")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(&(String.downcase(String.trim(&1)) == "upgrade"))
  end

  defp websocket_header?(conn) do
    conn
    |> get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(String.trim(&1)) == "websocket"))
  end
end
