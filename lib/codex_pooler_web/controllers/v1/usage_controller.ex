defmodule CodexPoolerWeb.V1.UsageController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Usage
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.PublicGatewayDispatch

  def index(conn, params) do
    PublicGatewayDispatch.authenticated(conn, RouteClass.proxy_http(), "/v1/usage", fn auth ->
      Usage.v1_usage(auth, params, request_options(conn))
    end)
  end

  defp request_options(conn) do
    conn
    |> GatewayHelpers.request_opts()
    |> RequestOptions.from_conn_metadata("/v1/usage", %{})
  end
end
