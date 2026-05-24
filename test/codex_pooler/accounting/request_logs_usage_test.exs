defmodule CodexPooler.Accounting.RequestLogsUsageTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Repo

  import CodexPooler.PoolerFixtures

  test "request log entries are metadata-only and usage shape is v1-compatible" do
    %{pool: pool, api_key: api_key} =
      active_api_key_fixture(pool_fixture(), %{
        default_policy: %{max_tokens_per_day: 1000, max_requests_per_minute: 60}
      })

    ensure_default_policy!(api_key)

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-log-mini",
        upstream_model_id: "provider-gpt-log-mini",
        pricing_ref: "provider-gpt-log-mini"
      })

    %{assignment: assignment} = upstream_assignment_fixture(pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %PricingSnapshot{
      model_identifier: "provider-gpt-log-mini",
      price_version: "test-v1",
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Decimal.new(100),
      cached_input_token_micros: Decimal.new(0),
      output_token_micros: Decimal.new(200),
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

    auth = %{pool: pool, api_key: api_key, key_prefix: api_key.key_prefix}

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               model,
               %{"model" => "gpt-log-mini", "input" => "raw input text"},
               %{
                 correlation_id: "corr-request-log",
                 user_agent: "Codex CLI/1.2.3",
                 request_metadata: %{
                   "body" => %{"input" => "raw input text"},
                   "safe_id" => "req_123"
                 }
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, assignment)

    assert {:ok, _result} =
             Accounting.finalize_success(
               reserved.request,
               attempt,
               %{status: "usage_known", input_tokens: 2, output_tokens: 3, total_tokens: 5},
               %{response_status_code: 200}
             )

    assert %{items: [log], total: 1, limit: 50, offset: 0} = Accounting.list_request_logs(pool)
    assert log.pool_name == pool.name
    assert log.pool_slug == pool.slug
    assert log.api_key_prefix == api_key.key_prefix
    assert log.requested_model == "gpt-log-mini"
    assert log.status == "succeeded"
    assert log.user_agent == "Codex CLI/1.2.3"
    assert log.pool_upstream_assignment_id == assignment.id
    assert log.token_counts.total_tokens == 5
    assert log.cost.status == "priced"
    assert Decimal.equal?(log.cost.usd, Decimal.new("0.000800"))
    assert log.metadata["body"] == "[REDACTED]"
    assert log.metadata["safe_id"] == "req_123"
    refute inspect(log) =~ "raw input text"

    assert {:ok, usage} =
             Accounting.build_api_key_self_usage(
               pool,
               api_key,
               as_of: DateTime.add(now, 60, :second)
             )

    assert usage.request_count == 1
    assert usage.total_tokens == 5
    assert Decimal.equal?(usage.total_cost_usd, Decimal.new("0.000800"))
    assert Enum.any?(usage.limits, &(&1.limit_type == "credits" and &1.limit_window == "daily"))

    assert {:ok, codex_usage} = Accounting.build_codex_usage_for_api_key(pool, api_key)
    assert codex_usage.plan_type == "api_key"
    assert codex_usage.rate_limit.allowed in [true, false]
  end

  defp ensure_default_policy!(api_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.one(
           from b in APIKeyPolicyBinding,
             where: b.api_key_id == ^api_key.id and b.binding_scope == "default",
             limit: 1
         ) do
      %APIKeyPolicyBinding{} = binding ->
        binding
        |> Ecto.Changeset.change(%{
          max_tokens_per_day: 1000,
          max_requests_per_minute: 60,
          updated_at: now
        })
        |> Repo.update!()

      nil ->
        %APIKeyPolicyBinding{
          api_key_id: api_key.id,
          binding_scope: "default",
          status: "active",
          max_tokens_per_day: 1000,
          max_requests_per_minute: 60,
          created_at: now,
          updated_at: now
        }
        |> Repo.insert!()
    end
  end
end
