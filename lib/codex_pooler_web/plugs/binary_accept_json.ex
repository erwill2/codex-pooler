defmodule CodexPoolerWeb.Plugs.BinaryAcceptJson do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "accept") do
      ["application/binary"] -> put_req_header(conn, "accept", "application/json")
      _other -> conn
    end
  end
end
