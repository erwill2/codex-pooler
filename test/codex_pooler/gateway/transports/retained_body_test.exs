defmodule CodexPooler.Gateway.Transports.Streaming.RetainedBodyTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.RetainedBody

  test "emits telemetry when a retained body first crosses the truncation limit" do
    attach_stream_buffer_telemetry()

    body = String.duplicate("x", RetainedBody.max_bytes() - 8)
    data = String.duplicate("y", 16)

    retained = RetainedBody.append(body, data)

    assert byte_size(retained) == RetainedBody.max_bytes()

    assert_receive {[:codex_pooler, :gateway, :stream_buffer, :truncated],
                    %{bytes: bytes, count: 1, max_bytes: 65_536},
                    %{buffer: "retained_body", endpoint: "unknown", route_class: "unknown"}}

    assert bytes > 65_536
  end

  defp attach_stream_buffer_telemetry do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:codex_pooler, :gateway, :stream_buffer, :truncated],
      fn event, measurements, metadata, _config ->
        send(parent, {event, measurements, metadata})
      end,
      :ok
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
