defmodule CodexPoolerWeb.Runtime.CodexUsageControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [monthly_only_account_primary_quota_window_attrs: 1]

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams

  @reset_credit_routes [
    {"/api/codex/rate-limit-reset-credits/consume",
     "/api/codex/rate-limit-reset-credits/consume"},
    {"/wham/rate-limit-reset-credits/consume", "/wham/rate-limit-reset-credits/consume"},
    {"/backend-api/wham/rate-limit-reset-credits/consume",
     "/wham/rate-limit-reset-credits/consume"}
  ]

  test "GET /api/codex/usage returns API-key Codex usage shape", %{conn: conn} do
    setup = active_api_key_fixture()

    conn =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> get("/api/codex/usage")

    assert %{"plan_type" => "api_key", "rate_limit" => rate_limit} = json_response(conn, 200)
    assert is_map(rate_limit)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/api/codex/usage"
    assert request.transport == "http_json"
    assert request.status == "succeeded"
    assert request.request_metadata["operation"] == "usage"
  end

  test "GET /backend-api/wham/usage is logged and returns the best routable upstream usage", %{
    conn: conn
  } do
    pool = pool_fixture()
    setup = active_api_key_fixture(pool)

    %{identity: free_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "usage-free-account",
        plan_family: "free"
      })

    %{identity: pro_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "usage-pro-account",
        plan_family: "pro"
      })

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(free_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(pro_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("12"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    conn =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("chatgpt-account-id", "usage-free-account")
      |> get("/backend-api/wham/usage")

    assert %{
             "plan_type" => "pro",
             "rate_limit" => %{
               "allowed" => true,
               "limit_reached" => false,
               "primary_window" => %{"used_percent" => 12}
             }
           } = json_response(conn, 200)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^pool.id))
    assert request.endpoint == "/backend-api/wham/usage"
    assert request.status == "succeeded"
    assert request.request_metadata["operation"] == "usage"
  end

  test "GET /api/codex/usage supports ChatGPT account usage branch", %{conn: conn} do
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "chatgpt-account-1"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "upstream-chatgpt-token"
             })

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("67"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               },
               %{
                 quota_key: "gpt_5_3_codex_spark",
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("55"),
                 display_label: "GPT-5.3-Codex-Spark",
                 limit_name: "codex_other",
                 metered_feature: "codex_bengalfox",
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    conn =
      conn
      |> put_req_header("authorization", "Bearer upstream-chatgpt-token")
      |> put_req_header("chatgpt-account-id", "chatgpt-account-1")
      |> get("/api/codex/usage")

    assert %{
             "plan_type" => plan_type,
             "credits" => %{"balance" => nil, "has_credits" => true},
             "rate_limit" => %{"primary_window" => %{"used_percent" => 67}},
             "additional_rate_limits" => [
               %{
                 "quota_key" => "codex_spark",
                 "display_label" => "GPT-5.3-Codex-Spark",
                 "metered_feature" => "codex_bengalfox",
                 "rate_limit" => %{"primary_window" => %{"used_percent" => 55}}
               }
             ]
           } = json_response(conn, 200)

    assert plan_type in ["unknown", "api_key"] or is_binary(plan_type)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^pool.id))
    assert request.api_key_id == nil
    assert request.endpoint == "/api/codex/usage"
    assert request.status == "succeeded"
    assert request.request_metadata["auth_mode"] == "chatgpt_account_token"
    assert request.upstream_account_label == identity.account_label
    assert is_nil(request.upstream_account_email)

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.api_key_id == nil
    assert log.upstream_account_label == identity.account_label
    assert is_nil(log.upstream_account_email)
  end

  test "GET /api/codex/usage ChatGPT token branch returns only that account usage", %{conn: conn} do
    pool = pool_fixture()

    %{identity: free_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "chatgpt-free-account",
        plan_family: "free"
      })

    %{identity: pro_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "chatgpt-pro-account",
        plan_family: "pro"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(free_identity, %{
               secret_kind: "access_token",
               plaintext: "free-upstream-token"
             })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(pro_identity, %{
               secret_kind: "access_token",
               plaintext: "pro-upstream-token"
             })

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(free_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(pro_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("5"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    conn =
      conn
      |> put_req_header("authorization", "Bearer free-upstream-token")
      |> put_req_header("chatgpt-account-id", "chatgpt-free-account")
      |> get("/api/codex/usage")

    assert %{
             "plan_type" => "free",
             "rate_limit" => %{
               "allowed" => false,
               "limit_reached" => true,
               "primary_window" => %{"used_percent" => 100}
             }
           } = json_response(conn, 200)
  end

  test "GET /api/codex/usage ChatGPT token branch selects the token-matched workspace slot", %{
    conn: conn
  } do
    pool = pool_fixture()
    account_id = "chatgpt-shared-account-#{System.unique_integer([:positive])}"

    %{identity: free_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        workspace_id: "ws_usage_free",
        plan_family: "free"
      })

    %{identity: pro_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        workspace_id: "ws_usage_pro",
        plan_family: "pro"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(free_identity, %{
               secret_kind: "access_token",
               plaintext: "free-slot-token"
             })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(pro_identity, %{
               secret_kind: "access_token",
               plaintext: "pro-slot-token"
             })

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(free_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("91"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(pro_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("4"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    conn =
      conn
      |> put_req_header("authorization", "Bearer free-slot-token")
      |> put_req_header("chatgpt-account-id", account_id)
      |> get("/api/codex/usage")

    assert %{
             "plan_type" => "free",
             "rate_limit" => %{"primary_window" => %{"used_percent" => 91}}
           } = json_response(conn, 200)
  end

  test "GET /api/codex/usage returns monthly-only primary window seconds without secondary synthesis",
       %{
         conn: conn
       } do
    pool = pool_fixture()
    now = ~U[2026-06-07 12:00:00Z]
    account_id = "monthly-account-#{System.unique_integer([:positive])}"

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        account_label: "Monthly usage account",
        plan_label: "Free-looking label"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "monthly-usage-token"
             })

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(identity, [
               monthly_only_account_primary_quota_window_attrs(%{
                 observed_at: now,
                 last_sync_at: now,
                 reset_at: DateTime.add(now, 30, :day)
               })
             ])

    conn =
      conn
      |> put_req_header("authorization", "Bearer monthly-usage-token")
      |> put_req_header("chatgpt-account-id", account_id)
      |> get("/api/codex/usage")

    assert %{
             "plan_type" => "unknown",
             "rate_limit" =>
               %{
                 "primary_window" =>
                   %{
                     "limit_window_seconds" => 2_592_000
                   } = primary_window
               } = rate_limit,
             "credits" => %{"balance" => nil}
           } = json_response(conn, 200)

    assert primary_window["used_percent"] == 43
    assert is_nil(rate_limit["secondary_window"])

    response_text = conn.resp_body
    refute response_text =~ "1134"
    refute response_text =~ "Free-looking label"
  end

  test "GET /api/codex/usage returns a statusful gateway error for inactive ChatGPT account usage",
       %{conn: conn} do
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "inactive-chatgpt-account",
        assignment_status: "disabled"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "inactive-account-token"
             })

    conn =
      conn
      |> put_req_header("authorization", "Bearer inactive-account-token")
      |> put_req_header("chatgpt-account-id", "inactive-chatgpt-account")
      |> get("/api/codex/usage")

    assert %{"error" => error} = json_response(conn, 404)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "invalid_chatgpt_account"
    assert error["message"] == "unknown or inactive chatgpt-account-id"
  end

  test "GET /api/codex/usage requires a bearer token for ChatGPT account mode", %{conn: conn} do
    conn = conn |> put_req_header("chatgpt-account-id", "acct") |> get("/api/codex/usage")

    assert json_response(conn, 401)["error"]["code"] == "invalid_authorization"
  end

  test "GET /api/codex/usage rejects invalid auth before admission", %{conn: conn} do
    attach_admission_probe()

    conn = conn |> put_req_header("chatgpt-account-id", "acct") |> get("/api/codex/usage")

    assert json_response(conn, 401)["error"]["code"] == "invalid_authorization"
    refute_received {:usage_admission_event, _event, _metadata}
  end

  test "GET /api/codex/usage rejects mismatched ChatGPT account token", %{conn: conn} do
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "chatgpt-account-2"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "real-token"
             })

    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong-token")
      |> put_req_header("chatgpt-account-id", "chatgpt-account-2")
      |> get("/api/codex/usage")

    assert json_response(conn, 401)["error"]["code"] == "invalid_authorization"
  end

  test "POST reset-credit consume authenticates before malformed JSON parsing" do
    for {path, _upstream_path} <- @reset_credit_routes do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(path, ~s({"redeem_request_id":))

      assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
    end

    assert Repo.aggregate(Request, :count, :id) == 0
  end

  test "POST reset-credit consume forwards exact sanitized JSON and records safe metadata" do
    upstream =
      start_upstream(
        FakeUpstream.json_response_with_headers(
          %{"outcome" => "reset"},
          [
            {"cache-control", "private, max-age=0"},
            {"request-id", "req_reset_credit_fixture"},
            {"x-request-id", "xreq_reset_credit_fixture"},
            {"set-cookie", "upstream_session=do-not-relay"}
          ]
        )
      )

    setup = reset_credit_gateway_setup(upstream)
    raw_redeem_request_id = "redeem-request-id-do-not-log"
    raw_idempotency_key = "raw-idempotency-key-do-not-forward"
    expected_body = Jason.encode!(%{"redeem_request_id" => raw_redeem_request_id})

    for {{path, upstream_path}, index} <- Enum.with_index(@reset_credit_routes, 1) do
      conn =
        build_conn()
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("idempotency-key", raw_idempotency_key)
        |> put_req_header("x-request-id", "client-reset-credit-request-#{index}")
        |> post(
          path,
          Jason.encode!(%{
            "redeem_request_id" => raw_redeem_request_id,
            "ignored" => "not-forwarded"
          })
        )

      assert %{"outcome" => "reset"} = json_response(conn, 200)
      assert get_resp_header(conn, "cache-control") == ["private, max-age=0"]
      assert get_resp_header(conn, "request-id") == ["req_reset_credit_fixture"]
      assert get_resp_header(conn, "x-request-id") == ["xreq_reset_credit_fixture"]
      assert get_resp_header(conn, "set-cookie") == []

      assert length(FakeUpstream.requests(upstream)) == index
      captured = upstream |> FakeUpstream.requests() |> List.last()
      captured_headers = Map.new(captured.headers)

      assert captured.method == "POST"
      assert captured.path == upstream_path
      assert captured.query_string == ""
      assert captured.body == expected_body
      assert captured.json == %{"redeem_request_id" => raw_redeem_request_id}
      assert captured_headers["authorization"] == "Bearer reset-credit-upstream-token"
      assert captured_headers["content-type"] == "application/json"
      refute Map.has_key?(captured_headers, "idempotency-key")
      refute inspect(captured.headers) =~ raw_idempotency_key
      refute inspect(captured.headers) =~ setup.raw_key

      request =
        Repo.one!(
          from request in Request,
            where:
              request.pool_id == ^setup.pool.id and
                fragment("?->>? = ?", request.request_metadata, "endpoint", ^path),
            order_by: [desc: request.admitted_at],
            limit: 1
        )

      assert request.endpoint == reset_credit_accounting_endpoint(path)
      assert request.transport == "http_json"
      assert request.status == "succeeded"
      assert request.response_status_code == 200
      assert request.request_metadata["operation"] == "rate_limit_reset_credit_consume"
      assert request.request_metadata["endpoint"] == path
      assert request.request_metadata["request"]["body_bytes"] == byte_size(expected_body)
      assert request.request_metadata["request"]["content_type"] == "application/json"

      assert request.request_metadata["client_request_id"] ==
               "client-reset-credit-request-#{index}"

      assert request.request_metadata["routing"]["route_class"] == "proxy_http"
      assert request.request_metadata["routing"]["selected_assignment_id"] == setup.assignment.id
      assert request.request_metadata["routing"]["upstream_identity_id"] == setup.identity.id

      metadata_text = inspect(request.request_metadata)
      refute metadata_text =~ raw_redeem_request_id
      refute metadata_text =~ raw_idempotency_key
      refute metadata_text =~ setup.raw_key
      refute metadata_text =~ "reset-credit-upstream-token"
    end
  end

  test "POST reset-credit consume relays noCredit outcome status and body intact", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"outcome" => "noCredit"}, 409))
    setup = reset_credit_gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post_json("/wham/rate-limit-reset-credits/consume", %{
        "redeem_request_id" => "redeem-request-no-credit"
      })

    assert %{"outcome" => "noCredit"} = json_response(conn, 409)

    assert [request] =
             Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

    assert request.endpoint == "/wham/usage"
    assert request.request_metadata["endpoint"] == "/wham/rate-limit-reset-credits/consume"
    assert request.status == "failed"
    assert request.response_status_code == 409
    assert request.last_error_code == "upstream_status"
  end

  test "POST reset-credit consume rejects malformed payloads without upstream contact", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = reset_credit_gateway_setup(upstream)
    path = "/api/codex/rate-limit-reset-credits/consume"

    invalid_json_conn =
      conn
      |> recycle()
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(path, ~s({"redeem_request_id":))

    assert json_response(invalid_json_conn, 400)["error"]["code"] == "invalid_request"

    for payload <- [
          [],
          %{},
          %{"redeem_request_id" => ""},
          %{"redeem_request_id" => "   "},
          %{"redeem_request_id" => 123}
        ] do
      conn =
        conn
        |> recycle()
        |> auth(setup)
        |> post_json(path, payload)

      assert %{"error" => error} = json_response(conn, 400)
      assert error["code"] == "invalid_request"
      assert error["param"] in ["redeem_request_id", nil]
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count, :id) == 0
  end

  test "POST app-server reset-credit JSON-RPC route remains unsupported", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = reset_credit_gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post_json("/backend-api/codex/account/rateLimitResetCredit/consume", %{
        "redeem_request_id" => "unsupported-app-server-reset-credit"
      })

    assert response(conn, 404) =~ "Not Found"
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count, :id) == 0
  end

  defp attach_admission_probe do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:codex_pooler, :gateway, :admission, :accepted],
          [:codex_pooler, :gateway, :admission, :enqueued],
          [:codex_pooler, :gateway, :admission, :rejected]
        ],
        fn event, _measurements, metadata, test_pid ->
          send(test_pid, {:usage_admission_event, event, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp reset_credit_gateway_setup(upstream) do
    setup = active_api_key_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        metadata: %{"base_url" => FakeUpstream.url(upstream)},
        access_token: "reset-credit-upstream-token"
      })

    model_fixture(setup.pool, %{
      exposed_model_id: "gpt-reset-credit-fixture",
      upstream_model_id: "provider-reset-credit-fixture",
      metadata: %{"source_assignment_ids" => [assignment.id]},
      supports_responses: true,
      supports_streaming: false
    })

    Map.merge(setup, %{identity: identity, assignment: assignment})
  end

  defp post_json(conn, path, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(payload))
  end

  defp auth(conn, %{authorization: authorization}) do
    put_req_header(conn, "authorization", authorization)
  end

  defp reset_credit_accounting_endpoint("/wham/rate-limit-reset-credits/consume"),
    do: "/wham/usage"

  defp reset_credit_accounting_endpoint("/backend-api/wham/rate-limit-reset-credits/consume"),
    do: "/backend-api/wham/usage"

  defp reset_credit_accounting_endpoint(_path), do: "/api/codex/usage"

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end
end
