defmodule CodexPooler.Gateway.Routing.SessionContinuityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession}
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @endpoint "/backend-api/codex/responses"

  describe "filter_codex_session_assignment/2" do
    test "returns pinned reauth recovery only for revoked-refresh-token pinned assignments outside candidates" do
      setup = pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert error.status == 503
      assert error.code == "pinned_continuation_reauth_required"
      assert error.retryable == false
      assert error.requires_new_upstream_session == true
      assert error.recovery["kind"] == "restart_with_full_context"

      assert error.continuity_denial == %{
               "denial_family" => "pinned_continuation_reauth",
               "continuity_family" => "pinned_codex_session",
               "upstream_lifecycle_family" => "reauth_required",
               "token_refresh_reason_code_preview" => "refresh_token_revoked",
               "pool_upstream_assignment_id" => setup.pinned.assignment.id,
               "upstream_identity_id" => setup.pinned.identity.id
             }
    end

    test "loads persisted assignment state rather than trusting only the eligible candidate set" do
      setup = pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, %{code: "pinned_continuation_reauth_required"}} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)
    end

    test "keeps paused assignments generic" do
      setup = pinned_assignment_setup(assignment_status: "paused")
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert_session_assignment_unavailable(error)
    end

    test "keeps deleted assignments generic" do
      setup = pinned_assignment_setup(assignment_status: "deleted")
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert_session_assignment_unavailable(error)
    end

    test "keeps missing refresh token reauth generic" do
      setup = pinned_assignment_setup(token_refresh_reason_code: "missing_refresh_token")
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert_session_assignment_unavailable(error)
    end

    test "keeps malformed token refresh metadata generic" do
      setup = pinned_assignment_setup(identity_metadata: %{"token_refresh" => "reauth_required"})
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert_session_assignment_unavailable(error)
    end

    test "keeps generic reauth_required identity state without revoked refresh metadata generic" do
      setup =
        pinned_assignment_setup(
          identity_metadata: %{"token_refresh" => %{"status" => "reauth_required"}}
        )

      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert_session_assignment_unavailable(error)
    end
  end

  describe "PreDispatch.prepare/5" do
    test "previous_response_id alias can recover the pinned reauth classification without a live owner lease" do
      setup = pinned_assignment_setup()
      api_key = active_api_key_fixture(setup.pool)
      {:ok, auth} = Access.authenticate_authorization_header(api_key.authorization)
      previous_response_id = "resp_prev_#{System.unique_integer([:positive])}"

      session =
        setup
        |> codex_session_fixture(setup.pinned.assignment, api_key.api_key)
        |> register_previous_response_alias!(api_key.api_key, previous_response_id)

      assert is_nil(session.owner_lease_expires_at)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      payload = %{
        "model" => model.exposed_model_id,
        "input" => "hello",
        "previous_response_id" => previous_response_id
      }

      opts = RequestOptions.build(%{api_key_policy: auth.api_key}, @endpoint, payload)

      assert {:error, error} = PreDispatch.prepare(auth, @endpoint, payload, opts, model)
      assert error.code == "pinned_continuation_reauth_required"
      assert error.continuity_denial["pool_upstream_assignment_id"] == setup.pinned.assignment.id
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end
  end

  defp pinned_assignment_setup(attrs \\ []) do
    attrs = Map.new(attrs)
    pool = pool_fixture()

    pinned =
      upstream_assignment_fixture(pool, %{
        identity_status: Map.get(attrs, :identity_status, "reauth_required"),
        identity_metadata: Map.get(attrs, :identity_metadata, token_refresh_metadata(attrs)),
        assignment_status: Map.get(attrs, :assignment_status, "active"),
        health_status: Map.get(attrs, :health_status, "disabled"),
        eligibility_status: Map.get(attrs, :eligibility_status, "ineligible")
      })

    other = upstream_assignment_fixture(pool)

    %{
      pool: pool,
      pinned: pinned,
      other: other,
      other_candidate: {other.assignment, other.identity}
    }
  end

  defp token_refresh_metadata(attrs) do
    %{
      "token_refresh" => %{
        "status" => Map.get(attrs, :token_refresh_status, "reauth_required"),
        "reason" => %{
          "code" => Map.get(attrs, :token_refresh_reason_code, "refresh_token_revoked"),
          "message" => "synthetic token refresh state"
        }
      }
    }
  end

  defp codex_session_fixture(setup, %PoolUpstreamAssignment{} = assignment, api_key \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %CodexSession{
      pool_id: setup.pool.id,
      api_key_id: api_key && api_key.id,
      session_key: "session-#{System.unique_integer([:positive])}",
      pool_upstream_assignment_id: assignment.id,
      status: "active",
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp request_options_with_session(%CodexSession{} = session) do
    %{}
    |> RequestOptions.build(@endpoint, %{"model" => "gpt-5.5", "input" => "hello"})
    |> RequestOptions.put_continuity(codex_session: session)
  end

  defp register_previous_response_alias!(%CodexSession{} = session, api_key, previous_response_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %BridgeSessionAlias{}
    |> BridgeSessionAlias.changeset(%{
      codex_session_id: session.id,
      pool_id: session.pool_id,
      api_key_id: api_key.id,
      alias_kind: "previous_response_id",
      alias_hash: :crypto.hash(:sha256, previous_response_id),
      alias_preview: "synthetic-prev",
      status: "active",
      expires_at: DateTime.add(now, 300, :second),
      last_seen_at: now,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()

    session
  end

  defp model_for_assignments(pool, assignment_ids) do
    model_fixture(pool, %{
      exposed_model_id: "gpt-5.5-#{System.unique_integer([:positive])}",
      source_assignment_count: length(assignment_ids),
      metadata: %{"source_assignment_ids" => assignment_ids}
    })
  end

  defp assert_session_assignment_unavailable(error) do
    assert error.status == 503
    assert error.code == "session_assignment_unavailable"

    assert error.message ==
             "the upstream assignment for this Codex session is not currently available"

    assert error.param == "model"
    refute Map.has_key?(error, :recovery)
    refute Map.has_key?(error, :continuity_denial)
  end
end
