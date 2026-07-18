defmodule CodexPooler.Gateway.OpenAICompatibility.ChatCompletionsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.ChatCompletions
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  describe "normalize_stream_data/2" do
    test "carries split stream parser state explicitly" do
      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})

      split_event =
        [
          "event: response.output_text.delta\n",
          "data: ",
          Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "split answer"})
        ]
        |> IO.iodata_to_binary()

      assert {"", state} = ChatCompletions.normalize_stream_data(split_event, state)
      assert {chunk, _state} = ChatCompletions.normalize_stream_data("\n\n", state)

      assert chunk =~ "\"object\":\"chat.completion.chunk\""
      assert chunk =~ "\"role\":\"assistant\""
      assert chunk =~ "\"content\":\"split answer\""
      refute Process.get({:openai_chat_completions_stream_state, "gpt-example"})
    end

    test "normalizes split response.created blocks above the generic SSE buffer limit" do
      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})

      event =
        [
          "event: response.created\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.created",
            "response" => %{
              "id" => "resp_split_created",
              "model" => "gpt-example",
              "tools" => [
                %{
                  "type" => "function",
                  "name" => "synthetic_tool",
                  "description" => String.duplicate("synthetic description ", 5_000)
                }
              ]
            }
          })
        ]
        |> IO.iodata_to_binary()

      split_at = StreamProtocol.max_incomplete_sse_block_bytes() + 1
      first = binary_part(event, 0, split_at)
      second = binary_part(event, split_at, byte_size(event) - split_at)

      assert byte_size(event) > StreamProtocol.max_incomplete_sse_block_bytes()
      assert {"", state} = ChatCompletions.normalize_stream_data(first, state)

      assert {chunk, state} = ChatCompletions.normalize_stream_data(second <> "\n\n", state)

      assert chunk =~ "\"object\":\"chat.completion.chunk\""
      assert chunk =~ "\"role\":\"assistant\""
      refute chunk =~ "response.created"
      refute state.discarding_oversized?
    end

    test "discards pathological incomplete response.created blocks without raw passthrough" do
      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})

      oversized =
        [
          "event: response.created\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.created",
            "response" => %{
              "id" => "resp_pathological_created",
              "model" => "gpt-example",
              "tools" => [
                %{
                  "type" => "function",
                  "name" => "synthetic_tool",
                  "description" => String.duplicate("synthetic description ", 60_000)
                }
              ]
            }
          })
        ]
        |> IO.iodata_to_binary()

      assert {role_chunk, state} = ChatCompletions.normalize_stream_data(oversized, state)

      assert role_chunk =~ "\"object\":\"chat.completion.chunk\""
      assert role_chunk =~ "\"role\":\"assistant\""
      refute role_chunk =~ "response.created"
      refute role_chunk =~ "synthetic description"
      assert state.discarding_oversized?

      delta =
        [
          "event: response.output_text.delta\n",
          "data: ",
          Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "after overflow"}),
          "\n\n"
        ]
        |> IO.iodata_to_binary()

      assert {delta_chunk, state} = ChatCompletions.normalize_stream_data("\n\n" <> delta, state)

      assert delta_chunk =~ "\"content\":\"after overflow\""
      refute delta_chunk =~ "response.output_text.delta"
      refute state.discarding_oversized?
    end

    test "does not replay function arguments from a completed output item" do
      arguments = ~s({"file_path":"","name":"hermes-agent"})

      events = [
        function_call_item_event("response.output_item.added", arguments),
        function_call_item_event("response.output_item.done", arguments)
      ]

      {stream, _state} = normalize_events(events)

      assert tool_argument_fragments(stream) == [arguments]
      assert tool_call_ids(stream) == ["call_hermes"]
    end

    test "converts cumulative function argument snapshots into non-overlapping deltas" do
      arguments = ~s({"file_path":"references/native-mcp.md","name":"hermes-agent"})

      events = [
        function_call_item_event("response.output_item.added", ""),
        function_arguments_event(~s({"file)),
        function_arguments_event(~s({"file_path":"references/)),
        function_arguments_event(arguments),
        function_call_item_event("response.output_item.done", arguments)
      ]

      {stream, _state} = normalize_events(events)

      assert tool_argument_fragments(stream) |> Enum.join() == arguments
      assert tool_call_ids(stream) == ["call_hermes"]
    end

    test "preserves true argument deltas and reconciles a missing suffix from done" do
      arguments = ~s({"file_path":"references/native-mcp.md","name":"hermes-agent"})

      events = [
        function_call_item_event("response.output_item.added", ""),
        function_arguments_event(~s({"file)),
        function_arguments_event(~s(_path":"references/)),
        function_arguments_done_event(arguments)
      ]

      {stream, _state} = normalize_events(events)

      assert tool_argument_fragments(stream) |> Enum.join() == arguments
      assert tool_call_ids(stream) == ["call_hermes"]
    end
  end

  defp normalize_events(events) do
    Enum.reduce(
      events,
      {"", ChatCompletions.stream_state(%{"model" => "gpt-example"})},
      fn event, {stream, state} ->
        {chunk, state} = ChatCompletions.normalize_stream_data(event, state)
        {stream <> chunk, state}
      end
    )
  end

  defp function_call_item_event(type, arguments) do
    sse_event(type, %{
      "type" => type,
      "output_index" => 0,
      "item" => %{
        "type" => "function_call",
        "id" => "fc_hermes",
        "call_id" => "call_hermes",
        "name" => "read_file",
        "arguments" => arguments
      }
    })
  end

  defp function_arguments_event(arguments) do
    sse_event("response.function_call_arguments.delta", %{
      "type" => "response.function_call_arguments.delta",
      "output_index" => 0,
      "item_id" => "fc_hermes",
      "delta" => arguments
    })
  end

  defp function_arguments_done_event(arguments) do
    sse_event("response.function_call_arguments.done", %{
      "type" => "response.function_call_arguments.done",
      "output_index" => 0,
      "item_id" => "fc_hermes",
      "arguments" => arguments
    })
  end

  defp sse_event(type, payload) do
    ["event: ", type, "\n", "data: ", Jason.encode!(payload), "\n\n"]
    |> IO.iodata_to_binary()
  end

  defp tool_argument_fragments(stream) do
    stream
    |> chat_chunks()
    |> Enum.flat_map(fn chunk ->
      case get_in(chunk, ["choices", Access.at(0), "delta", "tool_calls"]) do
        tool_calls when is_list(tool_calls) ->
          Enum.flat_map(tool_calls, fn tool_call ->
            case get_in(tool_call, ["function", "arguments"]) do
              arguments when is_binary(arguments) and arguments != "" -> [arguments]
              _arguments -> []
            end
          end)

        _tool_calls ->
          []
      end
    end)
  end

  defp tool_call_ids(stream) do
    stream
    |> chat_chunks()
    |> Enum.flat_map(fn chunk ->
      case get_in(chunk, ["choices", Access.at(0), "delta", "tool_calls"]) do
        tool_calls when is_list(tool_calls) ->
          Enum.flat_map(tool_calls, fn
            %{"id" => id} when is_binary(id) -> [id]
            _tool_call -> []
          end)

        _tool_calls ->
          []
      end
    end)
  end

  defp chat_chunks(stream) do
    stream
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      case StreamProtocol.sse_field(block, "data") do
        nil -> []
        "[DONE]" -> []
        data -> [Jason.decode!(data)]
      end
    end)
  end
end
