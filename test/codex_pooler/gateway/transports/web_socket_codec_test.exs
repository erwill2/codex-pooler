defmodule CodexPooler.Gateway.Transports.Streaming.WebSocketCodecTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.WebSocketCodec

  describe "decode_payload/1" do
    test "accepts response.create through the generic object contract" do
      payload = Jason.encode!(%{"type" => "response.create", "model" => "gpt-example"})

      assert {:ok, %{"type" => "response.create", "model" => "gpt-example"}} =
               WebSocketCodec.decode_payload(payload)
    end

    test "rejects invalid JSON and non-object JSON" do
      assert WebSocketCodec.decode_payload("[1,2,3]") == {:error, :not_object}
      assert WebSocketCodec.decode_payload("{invalid") == {:error, :invalid_json}
    end
  end

  describe "deliver_result/2" do
    test "normalizes websocket stream success tuples to :ok" do
      result = %{websocket_stream: fn -> {:ok, :done} end}

      assert WebSocketCodec.deliver_result(result, &unexpected_push/1) == :ok
    end

    test "preserves structured websocket stream errors" do
      error = %{status: 503, code: "upstream_stream_error", message: "upstream stream failed"}
      result = %{websocket_stream: fn -> {:error, error} end}

      assert WebSocketCodec.deliver_result(result, &unexpected_push/1) == {:error, error}
    end

    test "sanitizes structured websocket errors with invalid code types" do
      error = %{status: 503, code: {:closed, "sensitive detail"}, message: "upstream failed"}
      result = %{websocket_stream: fn -> {:error, error} end}

      assert {:error, sanitized} = WebSocketCodec.deliver_result(result, &unexpected_push/1)
      assert sanitized.status == 502
      assert sanitized.code == "websocket_stream_error"
      assert sanitized.message == "websocket stream failed"
      refute inspect(sanitized) =~ "sensitive detail"
    end

    test "sanitizes unexpected websocket stream results" do
      result = %{websocket_stream: fn -> {:error, {:closed, "sensitive transport detail"}} end}

      assert {:error, error} = WebSocketCodec.deliver_result(result, &unexpected_push/1)
      assert error.status == 502
      assert error.code == "websocket_stream_error"
      assert error.message == "websocket stream failed"
      refute inspect(error) =~ "sensitive transport detail"
    end
  end

  describe "stream_messages/3" do
    test "returns explicit buffer for split SSE frames without process state" do
      request_id = "websocket-buffer-explicit"

      assert {[], buffer} =
               WebSocketCodec.stream_messages(request_id, "data: {\"type\":\"response.", "")

      assert buffer == "data: {\"type\":\"response."

      assert {[message], ""} =
               WebSocketCodec.stream_messages(
                 request_id,
                 "completed\",\"response\":{\"id\":\"resp_123\"}}\n\n",
                 buffer
               )

      assert Jason.decode!(message)["type"] == "response.completed"
      refute Process.get({:websocket_sse_buffer, request_id})
    end

    test "drops oversized incomplete SSE buffers instead of retaining them" do
      attach_stream_buffer_telemetry()
      request_id = "websocket-buffer-oversized"
      oversized = String.duplicate("data: unavailable-upstream-prefix", 12_000)

      assert {[], ""} = WebSocketCodec.stream_messages(request_id, oversized, "")

      assert_receive {[:codex_pooler, :gateway, :stream_buffer, :oversized],
                      %{bytes: bytes, count: 1, max_bytes: 65_536},
                      %{buffer: "websocket_sse", endpoint: "unknown", route_class: "unknown"}}

      assert bytes > 65_536
    end
  end

  defp unexpected_push(_frame), do: flunk("websocket stream results should not push directly")

  defp attach_stream_buffer_telemetry do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:codex_pooler, :gateway, :stream_buffer, :oversized],
      fn event, measurements, metadata, _config ->
        send(parent, {event, measurements, metadata})
      end,
      :ok
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
