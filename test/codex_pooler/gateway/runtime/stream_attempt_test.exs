defmodule CodexPooler.Gateway.Runtime.Streaming.StreamAttemptTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Streaming.StreamAttempt

  describe "classify_first_event/2" do
    test "buffers incomplete first SSE events before writing" do
      state = StreamAttempt.first_event_state()

      assert {:buffered, state} = StreamAttempt.classify_first_event("data: {\"type\"", state)

      assert {{:write, data}, state} =
               StreamAttempt.classify_first_event(
                 ":\"response.created\"}\n\n",
                 state
               )

      assert data == "data: {\"type\":\"response.created\"}\n\n"
      assert state == %{classified?: true, buffer: ""}
      refute Process.get({:codex_first_stream_event_state, "attempt-stream-classification"})
      refute Process.get({:codex_first_stream_event_buffer, "attempt-stream-classification"})
    end

    test "classifies retryable first terminal failures without writing them" do
      state = StreamAttempt.first_event_state()

      data =
        "event: response.failed\n" <>
          "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\"}}}\n\n"

      assert {{:retry, %{code: "server_error", event_type: "response.failed"}}, state} =
               StreamAttempt.classify_first_event(data, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "classifies overloaded first terminal failures as retryable" do
      state = StreamAttempt.first_event_state()

      data =
        "event: response.failed\n" <>
          "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"overloaded_error\"}}}\n\n"

      assert {{:retry, %{code: "overloaded_error", event_type: "response.failed"}}, state} =
               StreamAttempt.classify_first_event(data, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "detects terminal failures after the first event is classified" do
      state = StreamAttempt.first_event_state()

      assert {{:write, _data}, state} =
               StreamAttempt.classify_first_event(
                 ~s[event: response.created\ndata: {"type":"response.created"}\n\n],
                 state
               )

      terminal =
        "event: response.failed\n" <>
          "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"bad_request\"}}}\n\n"

      assert {{:write_terminal_failure, ^terminal, %{code: "bad_request"}}, state} =
               StreamAttempt.classify_first_event(terminal, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "rejects non-binary stream chunks instead of returning an invalid write classification" do
      state = StreamAttempt.first_event_state()

      assert_raise FunctionClauseError, fn ->
        StreamAttempt.classify_first_event(:not_a_stream_chunk, state)
      end
    end
  end
end
