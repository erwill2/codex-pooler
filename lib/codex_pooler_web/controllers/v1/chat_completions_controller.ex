defmodule CodexPoolerWeb.V1.ChatCompletionsController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.OpenAICompatibility.{Chat, ChatCompletions}
  alias CodexPoolerWeb.Runtime.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.V1.PublicGatewayDispatch

  def create(conn, params) do
    PublicGatewayDispatch.coerced(
      conn,
      fn -> Chat.coerce(params, request_opts(conn, params)) end,
      fn decoded, %{chat_payload: chat_payload} ->
        ChatCompletions.normalize_response(decoded, chat_payload)
      end
    )
  end

  defp request_opts(conn, params) do
    conn
    |> GatewayHelpers.request_opts()
    |> Map.put(:upstream_endpoint, "/backend-api/codex/responses")
    |> maybe_mark_public_stream(params)
  end

  defp maybe_mark_public_stream(opts, %{"stream" => true} = params),
    do: opts |> Map.put(:public_openai_chat_stream, true) |> Map.put(:openai_chat_payload, params)

  defp maybe_mark_public_stream(opts, params),
    do:
      opts
      |> Map.put(:collect_openai_response_stream, true)
      |> Map.put(:openai_chat_payload, params)
end
