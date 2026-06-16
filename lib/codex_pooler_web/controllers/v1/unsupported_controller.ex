defmodule CodexPoolerWeb.V1.UnsupportedController do
  use CodexPoolerWeb, :controller

  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers

  @not_implemented %{
    status: 404,
    code: "unsupported_endpoint",
    message: "Unsupported OpenAI /v1 endpoint"
  }

  def unsupported_get(conn, params), do: unsupported(conn, params)
  def unsupported_post(conn, params), do: unsupported(conn, params)
  def unsupported_delete(conn, params), do: unsupported(conn, params)
  def unsupported(conn, _params), do: GatewayHelpers.send_error(conn, @not_implemented)
end
