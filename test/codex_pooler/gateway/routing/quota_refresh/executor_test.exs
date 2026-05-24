defmodule CodexPooler.Gateway.Routing.QuotaRefresh.ExecutorTest do
  use CodexPooler.DataCase, async: false

  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, prime_stale_routing_quota!: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.QuotaRefresh.Executor

  test "refresh failures stay best-effort and return the structured quota error" do
    upstream = start_upstream(FakeUpstream.json_response(%{}))
    setup = gateway_setup(upstream, quota?: false)
    prime_stale_routing_quota!(setup.identity)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    bad_assignment = %{setup.assignment | id: "not-a-uuid"}
    payload = %{"model" => setup.model.exposed_model_id, "input" => "stale quota"}

    request_options =
      RequestOptions.build(
        %{upstream_endpoint: "/backend-api/codex/responses"},
        "/backend-api/codex/responses",
        payload
      )

    filter_input =
      CandidateEligibility.FilterInput.new(%{
        auth: auth,
        model: setup.model,
        endpoint: "/backend-api/codex/responses",
        payload: payload,
        request_options: request_options,
        candidates: [{bad_assignment, setup.identity}]
      })

    assert {:refreshable_quota, plan} =
             CandidateEligibility.filter_quota_eligible_candidates(filter_input)

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  code: "quota_evidence_unavailable",
                  quota_refresh_attempted: true
                }} = Executor.refresh_stale_candidates(plan)
      end)

    assert log =~ "quota refresh skipped"
    assert log =~ "assignment_id=not-a-uuid"
    refute log =~ setup.raw_key
  end
end
