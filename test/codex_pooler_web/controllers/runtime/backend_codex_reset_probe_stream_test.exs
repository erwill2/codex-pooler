defmodule CodexPoolerWeb.Runtime.BackendCodexResetProbeStreamTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "SSE stream completion confirms the guarded reset probe upstream", %{conn: conn} do
    # Consume succeeds (credit spent) but the post-reset usage refresh OMITS the
    # account rate_limit window, so the account stays consumed_pending_probe and
    # the triggering request is force-routed as a one-shot guarded probe. The
    # stream completing successfully must flip the redemption phase to
    # confirmed_by_upstream via SideEffects.record_success/5.
    usage_upstream =
      start_upstream(
        {:path_json,
         %{
           "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           "/api/codex/usage" =>
             {200,
              %{"plan_type" => "pro", "rate_limit_reset_credits" => %{"available_count" => 0}}}
         }}
      )

    dispatch_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_reset_probe_stream",
               "status" => "completed",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(dispatch_upstream, quota?: false)
    identity = merge_saved_reset_identity_metadata!(setup.identity, usage_upstream)
    identity = enable_saved_reset_auto_redeem!(identity)
    prime_weekly_exhausted_quota!(identity)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "stream" => true,
        "input" => "reset probe stream fixture"
      })

    assert conn.status == 200
    assert conn.resp_body =~ "resp_reset_probe_stream"

    # Exactly one credit is consumed; the post-reset refresh then probes the
    # configured usage path first and may fall back to alternate read-only
    # usage paths when the account window is omitted.
    assert [consume_request | usage_requests] = FakeUpstream.requests(usage_upstream)
    assert consume_request.method == "POST"
    assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
    assert [%{method: "GET", path: "/api/codex/usage"} | _fallback_probes] = usage_requests
    assert Enum.all?(usage_requests, &(&1.method == "GET"))

    assert [response_request] = FakeUpstream.requests(dispatch_upstream)
    assert response_request.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == "http_sse"
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "reset_probe"

    assert get_in(request.request_metadata, [
             "quota_decision",
             "reset_probe",
             "upstream_identity_id"
           ]) == identity.id

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
    assert redemption["phase"] == "confirmed_by_upstream"
    assert get_in(redemption, ["result", "code"]) == "reset"
  end

  defp merge_saved_reset_identity_metadata!(%UpstreamIdentity{} = identity, upstream) do
    identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.merge(identity.metadata || %{}, saved_reset_metadata(upstream, 1)),
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp enable_saved_reset_auto_redeem!(%UpstreamIdentity{} = identity) do
    identity
    |> UpstreamIdentity.changeset(%{
      saved_reset_auto_redeem_enabled: true,
      saved_reset_auto_redeem_min_blocked_minutes: 60,
      saved_reset_auto_redeem_keep_credits: 0,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end
end
