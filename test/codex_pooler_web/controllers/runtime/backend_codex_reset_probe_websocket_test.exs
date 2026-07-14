defmodule CodexPoolerWeb.Runtime.BackendCodexResetProbeWebsocketTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway, as: RuntimeGateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @websocket_frame_timeout 1_000

  test "successful websocket response confirms the guarded reset probe" do
    # Auto redemption consumes the saved reset, but the post-consume usage
    # refresh OMITS the account rate_limit window, so the redemption parks in
    # consumed_pending_probe and the triggering request is force-routed as the
    # one-shot guarded probe. Its websocket-transport success must flip the
    # phase to confirmed_by_upstream through the shared finalization side
    # effects.
    #
    # FakeUpstream cannot serve :path_json over a websocket upgrade, so the
    # dispatch upstream (websocket SSE) and the usage/consume upstream
    # (:path_json) are split: the assignment's base_url points at the dispatch
    # upstream while the identity's usage_base_url points at the usage
    # upstream, matching how EndpointMetadata resolves each endpoint.
    dispatch_upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created",
           %{
             "type" => "response.created",
             "response" => %{"id" => "resp_ws_reset_probe_confirmed"}
           }},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_ws_reset_probe_confirmed",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

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

    setup = gateway_setup(dispatch_upstream, quota?: false)

    identity =
      setup.identity
      |> UpstreamIdentity.changeset(%{
        metadata: saved_reset_metadata(usage_upstream, 1),
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    prime_weekly_exhausted_quota!(identity)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    parent = self()

    result =
      RuntimeGateway.execute_websocket_response(
        auth,
        Jason.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => "guarded reset probe over websocket",
          "stream" => true,
          "generate" => true
        }),
        RequestOptions.for_websocket(%{request_id: "ws-reset-probe"}),
        fn frame -> send(parent, {:websocket_frame, frame}) end
      )

    assert result == :ok
    assert_receive {:websocket_frame, created_frame}, @websocket_frame_timeout
    assert_receive {:websocket_frame, completed_frame}, @websocket_frame_timeout
    assert %{"type" => "response.created"} = Jason.decode!(created_frame)
    assert %{"type" => "response.completed"} = Jason.decode!(completed_frame)

    usage_requests = FakeUpstream.requests(usage_upstream)

    assert [%{method: "POST", json: %{"redeem_request_id" => _}}] =
             Enum.filter(
               usage_requests,
               &(&1.path == "/api/codex/rate-limit-reset-credits/consume")
             )

    assert Enum.any?(usage_requests, &(&1.method == "GET" and &1.path == "/api/codex/usage"))

    assert [dispatch_request] = FakeUpstream.requests(dispatch_upstream)
    assert dispatch_request.method == "WEBSOCKET"
    assert dispatch_request.json["type"] == "response.create"

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
