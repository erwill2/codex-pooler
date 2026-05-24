defmodule CodexPooler.Gateway.Runtime.Streaming.DownstreamStream do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.ChatCompletions
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @type state :: map()

  @spec initial_state(term(), RequestOptions.t()) :: state()
  def initial_state(target, %RequestOptions{} = opts) do
    state = %{target: target}

    cond do
      public_openai_chat_stream?(opts) ->
        Map.put(
          state,
          :public_openai_chat,
          ChatCompletions.stream_state(openai_chat_payload(opts))
        )

      public_openai_responses_stream?(opts) ->
        Map.put(
          state,
          :public_openai_responses,
          StreamProtocol.public_openai_responses_stream_state()
        )

      true ->
        state
    end
  end

  @spec endpoint(map(), RequestOptions.t()) :: String.t() | nil
  def endpoint(_payload, %RequestOptions{
        transport: %{upstream_endpoint: endpoint}
      })
      when is_binary(endpoint),
      do: endpoint

  def endpoint(_payload, _opts), do: nil

  @spec normalize_data(iodata(), String.t() | nil, RequestOptions.t(), state()) ::
          {iodata(), state()}
  def normalize_data(data, endpoint, %RequestOptions{} = opts, state) do
    cond do
      public_openai_chat_stream?(opts) ->
        normalize_public_openai_chat_stream_data(data, state)

      public_openai_responses_stream?(opts) ->
        normalize_public_openai_responses_stream_data(data, state)

      true ->
        {normalize_endpoint_data(endpoint, data), state}
    end
  end

  defp normalize_public_openai_chat_stream_data(
         data,
         %{public_openai_chat: stream_state} = state
       ) do
    {data, stream_state} = ChatCompletions.normalize_stream_data(data, stream_state)
    {data, %{state | public_openai_chat: stream_state}}
  end

  defp normalize_public_openai_chat_stream_data(data, state), do: {data, state}

  defp normalize_public_openai_responses_stream_data(
         data,
         %{public_openai_responses: stream_state} = state
       ) do
    {data, stream_state} =
      StreamProtocol.normalize_public_openai_responses_sse_data(data, stream_state)

    {data, %{state | public_openai_responses: stream_state}}
  end

  defp normalize_public_openai_responses_stream_data(data, state), do: {data, state}

  defp normalize_endpoint_data("/backend-api/codex/responses", data) when is_binary(data) do
    StreamProtocol.normalize_codex_responses_sse_data(data)
  end

  defp normalize_endpoint_data("/backend-api/codex/responses/compact", data)
       when is_binary(data) do
    StreamProtocol.normalize_codex_responses_sse_data(data)
  end

  defp normalize_endpoint_data(_endpoint, data), do: data

  defp public_openai_responses_stream?(%RequestOptions{
         openai_compatibility: %{public_openai_responses_stream: true}
       }),
       do: true

  defp public_openai_responses_stream?(_opts), do: false

  defp public_openai_chat_stream?(%RequestOptions{
         openai_compatibility: %{public_openai_chat_stream: true}
       }),
       do: true

  defp public_openai_chat_stream?(_opts), do: false

  defp openai_chat_payload(%RequestOptions{
         openai_compatibility: %{openai_chat_payload: %{} = payload}
       }),
       do: payload

  defp openai_chat_payload(_opts), do: %{}
end
