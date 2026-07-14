defmodule CodexPoolerWeb.Runtime.BackendCodexResetProbeTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "successful HTTP JSON response confirms the guarded reset probe", %{conn: conn} do
    # Auto redemption consumes the saved reset, but the post-consume usage
    # refresh OMITS the account rate_limit window, so the redemption parks in
    # consumed_pending_probe and the triggering request is force-routed as the
    # one-shot guarded probe. Its non-streaming success must flip the phase to
    # confirmed_by_upstream through the shared finalization side effects.
    upstream =
      start_upstream(
        {:path_json,
         %{
           "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           "/api/codex/usage" =>
             {200,
              %{"plan_type" => "pro", "rate_limit_reset_credits" => %{"available_count" => 0}}},
           "/backend-api/codex/responses" =>
             {200,
              %{
                "id" => "resp_reset_probe_confirmed",
                "object" => "response",
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
              }}
         }}
      )

    setup = gateway_setup(upstream, quota?: false)

    identity =
      setup.identity
      |> UpstreamIdentity.changeset(%{
        metadata: saved_reset_metadata(upstream, 1),
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    prime_weekly_exhausted_quota!(identity)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "guarded reset probe",
        "stream" => false
      })

    assert %{"id" => "resp_reset_probe_confirmed"} = json_response(conn, 200)

    requests = FakeUpstream.requests(upstream)

    assert [%{method: "POST", json: %{"redeem_request_id" => _}}] =
             Enum.filter(requests, &(&1.path == "/api/codex/rate-limit-reset-credits/consume"))

    assert %{method: "POST", path: "/backend-api/codex/responses"} = List.last(requests)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "reset_probe"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
    assert redemption["phase"] == "confirmed_by_upstream"
    assert get_in(redemption, ["result", "code"]) == "reset"
  end
end
