defmodule CodexPooler.Accounting.RequestLogsDetailsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Repo

  import CodexPooler.PoolerFixtures

  test "request log rows expose snapshots model settings route and cached token counts" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    pricing_snapshot =
      %PricingSnapshot{
        model_identifier: "gpt-row-shape",
        price_version: "test-cache-cost",
        currency_code: "USD",
        billing_unit: "token",
        input_token_micros: Decimal.new(10),
        cached_input_token_micros: Decimal.new(3),
        output_token_micros: Decimal.new(20),
        reasoning_token_micros: Decimal.new(0),
        request_base_micros: Decimal.new(0),
        effective_at: DateTime.add(now, -60, :second),
        captured_at: now,
        config: %{
          "service_tier" => "standard",
          "price_bucket" => "default",
          "pricing_type" => "per_1m_tokens"
        }
      }
      |> Repo.insert!()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-row-shape",
        endpoint: "/backend-api/codex/responses/compact",
        transport: "http_json",
        status: "succeeded",
        usage_status: "usage_known",
        correlation_id: "row-shape-compact-route"
      })
      |> Ecto.Changeset.change(%{
        upstream_account_label: "operator@example.com",
        upstream_account_email: "operator@example.com",
        upstream_account_plan_label: "chatgpt pro",
        upstream_account_plan_family: "paid",
        reasoning_effort: "high",
        service_tier: "priority",
        requested_service_tier: "auto",
        actual_service_tier: "priority"
      })
      |> Repo.update!()

    attempt = attempt_fixture(request, assignment)

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pricing_snapshot_id: pricing_snapshot.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      input_tokens: 11,
      cached_input_tokens: 4,
      output_tokens: 7,
      reasoning_tokens: 3,
      total_tokens: 21,
      settled_cost_micros: 42_000,
      details: %{"pricing_status" => "priced", "settled_cost_micros" => "42000"}
    })

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.id == request.id
    assert log.upstream_account_label == "operator@example.com"
    assert log.upstream_account_email == "operator@example.com"
    assert log.upstream_account_plan_label == "chatgpt pro"
    assert log.upstream_account_plan_family == "paid"
    assert log.upstream_identity_label == identity.account_label
    assert log.reasoning_effort == "high"
    assert log.service_tier == "priority"
    assert log.requested_service_tier == "auto"
    assert log.actual_service_tier == "priority"
    assert log.endpoint == "/backend-api/codex/responses/compact"
    assert log.transport == "http_json"
    assert log.token_counts.input_tokens == 11
    assert log.token_counts.cached_input_tokens == 4
    assert Decimal.equal?(log.token_counts.cached_input_cost_usd, Decimal.new("0.000012"))
    assert log.token_counts.output_tokens == 7
    assert log.token_counts.reasoning_tokens == 3
    assert log.token_counts.total_tokens == 21
    assert log.cost.status == "priced"
    assert Decimal.equal?(log.cost.usd, Decimal.new("0.042000"))
    assert log.errors == []
  end

  test "request log rows aggregate all sanitized denial attempt degraded and retryable errors" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    secret_token = "Bearer sk-cxp-abcdef123456-secretValue"
    raw_body = "raw upstream body must not leak"

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-errors-log",
        status: "failed",
        usage_status: "usage_unknown",
        correlation_id: "row-errors",
        request_metadata: %{
          "routing" => %{
            "strategy" => "bridge_ring",
            "demotion_reason" => "upstream_5xx",
            "authorization" => secret_token
          },
          "candidate_exclusions" => [
            %{
              "reasons" => [
                %{"code" => "routing_circuit_open", "message" => secret_token},
                %{"code" => "quota_stale"}
              ]
            }
          ],
          "retryable_summary" => %{
            "code" => "retryable_upstream_status",
            "message" => "first backend can be retried",
            "authorization" => secret_token
          },
          "body" => %{"input" => raw_body}
        }
      })
      |> Ecto.Changeset.change(%{last_error_code: "quota_account_primary_unknown"})
      |> Repo.update!()

    request
    |> attempt_fixture(assignment, %{attempt_number: 1})
    |> Ecto.Changeset.change(%{
      status: "retryable_failed",
      retryable: true,
      network_error_code: "retryable_upstream_status",
      error_message: secret_token,
      upstream_status_code: 502,
      response_metadata: %{
        "error_code" => "retryable_upstream_status",
        "message" => "upstream returned 502",
        "authorization" => secret_token,
        "body" => raw_body
      }
    })
    |> Repo.update!()

    request
    |> attempt_fixture(assignment, %{attempt_number: 2})
    |> Ecto.Changeset.change(%{
      status: "failed",
      retryable: false,
      network_error_code: "upstream_status",
      error_message: "safe upstream status",
      upstream_status_code: 400,
      response_metadata: %{
        "error_code" => "upstream_status",
        "message" => "upstream rejected request",
        "raw_response" => raw_body
      }
    })
    |> Repo.update!()

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.denial_reason == "quota_account_primary_unknown"
    assert log.metadata["body"] == "[REDACTED]"
    assert log.metadata["routing"]["authorization"] == "[REDACTED]"

    assert Enum.any?(
             log.errors,
             &(&1.source == "request" and &1.code == "quota_account_primary_unknown")
           )

    assert Enum.any?(log.errors, &(&1.source == "metadata" and &1.code == "routing_circuit_open"))
    refute Enum.any?(log.errors, &(&1.source == "metadata" and &1.code == "upstream_5xx"))

    assert Enum.any?(log.errors, fn error ->
             error.source == "attempt" and error.attempt_number == 1 and
               error.code == "retryable_upstream_status" and error.retryable == true
           end)

    assert Enum.any?(log.errors, fn error ->
             error.source == "attempt" and error.attempt_number == 2 and
               error.code == "upstream_status" and error.upstream_status_code == 400
           end)

    assert length(log.errors) >= 4
    refute inspect(log.errors) =~ secret_token
    refute inspect(log.errors) =~ raw_body
    refute inspect(log) =~ secret_token
    refute inspect(log) =~ raw_body
  end
end
