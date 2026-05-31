defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.SSE do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @spec response_from_sse(binary()) :: {:ok, map()} | {:error, Error.reason()}
  def response_from_sse(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} ->
        {:ok, Map.put_new(decoded, "object", "response")}

      _error ->
        body |> decoded_sse_events() |> response_from_sse_events()
    end
  end

  defp response_from_sse_events(events) do
    with {:ok, response, event} <- terminal_response(events) do
      response =
        response
        |> Map.put_new("object", "response")
        |> maybe_backfill_output(events)

      terminal_error(event, response) || {:ok, response}
    end
  end

  defp decoded_sse_events(body) do
    body
    |> StreamProtocol.complete_sse_blocks(bounded?: false)
    |> elem(0)
    |> Enum.map(fn block ->
      block |> StreamProtocol.sse_field("data") |> StreamProtocol.decode_sse_data()
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  defp terminal_response(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"response" => %{} = response} = event -> {:ok, response, event}
      _event -> nil
    end)
    |> Kernel.||(
      {:error, Error.reason(502, "upstream_response_missing", "upstream response was incomplete")}
    )
  end

  defp terminal_error(_event, %{"status" => status}) when status in ["completed", "in_progress"],
    do: nil

  defp terminal_error(event, response) do
    error = response["error"] || event["error"]

    case error do
      %{} = error ->
        status = if Map.get(error, "type") == "invalid_request_error", do: 400, else: 502

        {:error,
         Error.reason(
           status,
           Map.get(error, "code") || "upstream_error",
           Map.get(error, "message") || "upstream response failed",
           Map.get(error, "param")
         )}

      _other ->
        {:error, Error.reason(502, "upstream_error", "upstream response failed")}
    end
  end

  defp maybe_backfill_output(%{"output" => output} = response, _events) when is_list(output),
    do: response

  defp maybe_backfill_output(response, events) do
    output_items =
      events
      |> Enum.flat_map(fn
        %{"type" => "response.output_item.done", "item" => %{} = item} -> [item]
        _event -> []
      end)

    cond do
      output_items != [] ->
        Map.put(response, "output", output_items)

      output_text = output_text_from_events(events) ->
        Map.put(response, "output", [
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => output_text}]}
        ])

      true ->
        response
    end
  end

  defp output_text_from_events(events) do
    deltas =
      events
      |> Enum.flat_map(fn
        %{"type" => "response.output_text.delta", "delta" => delta} when is_binary(delta) ->
          [delta]

        _event ->
          []
      end)

    done_texts =
      events
      |> Enum.flat_map(fn
        %{"type" => "response.output_text.done", "text" => text} when is_binary(text) -> [text]
        _event -> []
      end)

    [deltas, done_texts]
    |> Enum.find(&(&1 != []))
    |> case do
      nil -> nil
      parts -> Enum.join(parts)
    end
  end
end
