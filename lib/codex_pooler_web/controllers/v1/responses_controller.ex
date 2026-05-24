defmodule CodexPoolerWeb.V1.ResponsesController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPoolerWeb.Runtime.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.V1.PublicGatewayDispatch

  @compact_unsupported %{
    status: 404,
    code: "unsupported_endpoint",
    message: "Unsupported OpenAI /v1 endpoint",
    param: nil
  }

  def create(conn, params) do
    PublicGatewayDispatch.coerced(
      conn,
      fn -> Responses.coerce(params, request_opts(conn, params)) end,
      fn decoded, _coerced -> normalize_response_success(decoded) end
    )
  end

  def compact(conn, _params), do: GatewayHelpers.send_error(conn, @compact_unsupported)

  defp request_opts(conn, params) do
    conn
    |> GatewayHelpers.request_opts()
    |> Map.put(:upstream_endpoint, "/backend-api/codex/responses")
    |> maybe_mark_public_stream(params)
  end

  defp maybe_mark_public_stream(opts, %{"stream" => true}),
    do: Map.put(opts, :public_openai_responses_stream, true)

  defp maybe_mark_public_stream(opts, _params),
    do: Map.put(opts, :collect_openai_response_stream, true)

  defp normalize_response_success(decoded) do
    decoded
    |> Map.put_new("object", "response")
  end
end
