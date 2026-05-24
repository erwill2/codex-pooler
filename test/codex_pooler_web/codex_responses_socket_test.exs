defmodule CodexPoolerWeb.CodexResponsesSocketTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.CodexResponsesSocket

  test "websocket client error frames classify prompt token and idempotency-bearing terms" do
    secret_reason = %{
      idempotency_key: "raw-idempotency-key-secret",
      prompt: "raw websocket prompt",
      token: "Bearer websocket-secret-token"
    }

    state = %{tasks: MapSet.new(), task_monitors: %{}}

    assert {:push, {:text, payload}, ^state} =
             CodexResponsesSocket.handle_info(
               {:codex_response_done, self(), {:error, secret_reason}},
               state
             )

    decoded = Jason.decode!(payload)
    assert decoded["type"] == "error"
    assert decoded["status"] == 500
    assert decoded["error"]["message"] == "websocket request failed: non_atom_reason"
    assert decoded["error"]["code"] == "websocket_request_failed"

    refute payload =~ "raw-idempotency-key-secret"
    refute payload =~ "raw websocket prompt"
    refute payload =~ "websocket-secret-token"
  end
end
