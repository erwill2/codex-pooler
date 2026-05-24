defmodule CodexPooler.Gateway.Runtime.RateLimitObserverTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  describe "record_complete_events/2" do
    test "records a whole event payload without exposing streaming state" do
      identity = %UpstreamIdentity{id: Ecto.UUID.generate()}

      assert :ok =
               RateLimitObserver.record_complete_events(
                 identity,
                 "event: codex.rate_limits\n"
               )
    end
  end

  describe "record_events/3" do
    test "returns incomplete SSE buffer in explicit state" do
      identity = %UpstreamIdentity{id: Ecto.UUID.generate()}

      assert {:ok, %{buffer: "event: codex.rate_limits\n"}} =
               RateLimitObserver.record_events(
                 identity,
                 "event: codex.rate_limits\n",
                 RateLimitObserver.event_state()
               )

      refute Process.get({:codex_rate_limit_event_buffer, identity.id})
    end

    test "bounds incomplete SSE buffer state" do
      identity = %UpstreamIdentity{id: Ecto.UUID.generate()}

      assert {:ok, %{buffer: ""}} =
               RateLimitObserver.record_events(
                 identity,
                 String.duplicate("x", 16_385),
                 RateLimitObserver.event_state()
               )
    end
  end
end
