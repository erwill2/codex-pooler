defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @type state :: %{
          required(:buffer) => binary(),
          required(:created?) => boolean(),
          required(:text_delta?) => boolean()
        }

  @spec new_state() :: state()
  def new_state, do: %{buffer: "", created?: false, text_delta?: false}

  @spec normalize_data(binary(), state()) :: {binary(), state()}
  def normalize_data(data, state) when is_binary(data) do
    buffered_data = state.buffer <> data
    {blocks, buffer} = StreamProtocol.complete_sse_blocks(buffered_data, bounded?: true)

    if oversized_incomplete_sse_prefix?(blocks, buffer, buffered_data) do
      {buffered_data, %{state | buffer: ""}}
    else
      normalize_blocks(blocks, buffer, state)
    end
  end

  def normalize_data(data, state), do: {data, state}

  defp normalize_blocks(blocks, buffer, state) do
    {iodata, state} =
      Enum.map_reduce(blocks, %{state | buffer: buffer}, fn block, stream_state ->
        normalize_block(block, stream_state)
      end)

    state = if stream_terminal?(blocks), do: new_state(), else: state

    {IO.iodata_to_binary(iodata), state}
  end

  defp normalize_block("data: [DONE]", state), do: {[], state}

  defp normalize_block(block, state) do
    {event_type, decoded} = stream_block_event(block)
    type = event_type || decoded_string(decoded, "type")

    cond do
      codex_public_event?(type) ->
        {[], state}

      type == "response.created" ->
        {[public_sse_block("response.created", decoded)], %{state | created?: true}}

      type == "response.output_text.delta" ->
        {[public_sse_block("response.output_text.delta", decoded)], %{state | text_delta?: true}}

      terminal_event?(type) ->
        {prefix, state} = terminal_prefix(decoded, state)
        {[prefix, public_sse_block(type || "response.completed", decoded)], state}

      is_binary(type) ->
        {[public_sse_block(type, decoded)], state}

      true ->
        {[], state}
    end
  end

  defp oversized_incomplete_sse_prefix?([], "", data),
    do: StreamProtocol.oversized_incomplete_sse_block?(data)

  defp oversized_incomplete_sse_prefix?(_blocks, _buffer, _data), do: false

  defp terminal_prefix(decoded, state) do
    {created_prefix, state} =
      if state.created? do
        {[], state}
      else
        response_id =
          nested_string(decoded, ["response", "id"]) || decoded_string(decoded, "id") || ""

        created = %{
          "type" => "response.created",
          "response" => %{"id" => response_id, "object" => "response", "status" => "in_progress"}
        }

        {[public_sse_block("response.created", created)], %{state | created?: true}}
      end

    {delta_prefix, state} =
      if state.text_delta? do
        {[], state}
      else
        case terminal_output_text(decoded) do
          "" ->
            {[], state}

          text ->
            delta = %{"type" => "response.output_text.delta", "delta" => text}

            {[public_sse_block("response.output_text.delta", delta)],
             %{state | text_delta?: true}}
        end
      end

    {[created_prefix, delta_prefix], state}
  end

  defp public_sse_block(event_type, decoded) when is_binary(event_type) and is_map(decoded) do
    [
      "event: ",
      event_type,
      "\n",
      "data: ",
      Jason.encode!(Map.put_new(decoded, "type", event_type)),
      "\n\n"
    ]
  end

  defp terminal_output_text(decoded) do
    response = if is_map(decoded["response"]), do: decoded["response"], else: decoded

    response
    |> Map.get("output", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"content" => content} -> List.wrap(content)
      %{"text" => text} when is_binary(text) -> [%{"text" => text}]
      _item -> []
    end)
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "output_text", "text" => text} when is_binary(text) -> text
      _content -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("")
  end

  defp stream_terminal?(blocks) do
    Enum.any?(blocks, fn block ->
      {event_type, decoded} = stream_block_event(block)

      terminal_event?(event_type || decoded_string(decoded, "type")) or
        block == "data: [DONE]"
    end)
  end

  defp terminal_event?(type)
       when type in ["response.completed", "response.failed", "response.incomplete", "error"],
       do: true

  defp terminal_event?(_type), do: false

  defp codex_public_event?(type) when is_binary(type), do: String.starts_with?(type, "codex.")
  defp codex_public_event?(_type), do: false

  defp stream_block_event(block) do
    data = StreamProtocol.sse_field(block, "data")

    decoded =
      if is_binary(data),
        do: StreamProtocol.decode_sse_data(data),
        else: StreamProtocol.decode_sse_data(block)

    event_type = StreamProtocol.sse_field(block, "event") || decoded_string(decoded, "type")

    {event_type, decoded}
  end

  defp decoded_string(decoded, key) when is_map(decoded) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp nested_string(map, keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{^key => value} -> {:cont, value}
        _other -> {:halt, nil}
      end
    end)
    |> case do
      value when is_binary(value) -> value
      _value -> nil
    end
  end
end
