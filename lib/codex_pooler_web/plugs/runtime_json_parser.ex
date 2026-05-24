defmodule CodexPoolerWeb.Plugs.RuntimeJsonParser do
  @moduledoc false

  @behaviour Plug.Parsers

  alias Plug.Parsers.JSON

  alias CodexPoolerWeb.Plugs.RuntimeIngress

  @impl true
  def init(opts), do: JSON.init(opts)

  @impl true
  def parse(conn, type, subtype, headers, opts) do
    JSON.parse(conn, type, subtype, headers, opts)
  rescue
    error in Plug.Parsers.ParseError ->
      cond do
        RuntimeIngress.protected_backend_json_request?(conn) ->
          {:ok, %{"_invalid_json" => true},
           Plug.Conn.put_private(conn, :runtime_json_parse_error, true)}

        conn.path_info == ["mcp"] ->
          {:ok, %{"_invalid_json" => true},
           Plug.Conn.put_private(conn, :mcp_json_parse_error, true)}

        true ->
          reraise error, __STACKTRACE__
      end
  end
end
