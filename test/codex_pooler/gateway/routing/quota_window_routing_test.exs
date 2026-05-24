defmodule CodexPooler.Gateway.Routing.QuotaWindowRoutingTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows

  @observed_at ~U[2026-05-22 12:00:00Z]

  describe "routing_quota_eligibility_from_windows/2" do
    test "ordinary models stay eligible when Spark quota evidence is absent" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{primary: %AccountQuotaWindow{}, blocked_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows([account_primary_window()],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "ordinary models ignore unusable Spark quota evidence that is out of model scope" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{blocked_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [account_primary_window(), exhausted_spark_window()],
                 at: @observed_at,
                 model: "sample-codex-standard",
                 requested_model: "sample-codex-standard",
                 upstream_model: "sample-codex-standard-upstream"
               )
    end

    test "Spark model routing blocks when in-scope Spark quota evidence is unusable" do
      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_window_unusable",
                   quota_key: "codex_spark",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "sample-codex-spark",
                   reason_codes: ["exhausted"]
                 }
               ],
               selection: %{blocked_windows: [%AccountQuotaWindow{quota_key: "codex_spark"}]}
             } =
               Windows.routing_quota_eligibility_from_windows(
                 [account_primary_window(), exhausted_spark_window()],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end

    test "Spark model routing does not fail closed solely because no Spark-specific window exists" do
      assert %{
               eligible?: true,
               routing_state: :precise,
               exclusions: [],
               selection: %{primary: %AccountQuotaWindow{}, blocked_windows: []}
             } =
               Windows.routing_quota_eligibility_from_windows([account_primary_window()],
                 at: @observed_at,
                 model: "sample-codex-spark",
                 requested_model: "sample-codex-spark",
                 upstream_model: "sample-codex-spark-upstream"
               )
    end
  end

  defp account_primary_window do
    %AccountQuotaWindow{
      quota_key: "account",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new("12"),
      reset_at: DateTime.add(@observed_at, 900, :second),
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      observed_at: @observed_at
    }
  end

  defp exhausted_spark_window do
    %AccountQuotaWindow{
      quota_key: "codex_spark",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new("100"),
      reset_at: DateTime.add(@observed_at, 900, :second),
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "sample-codex-spark",
      upstream_model: "sample-codex-spark-upstream",
      freshness_state: "fresh",
      observed_at: @observed_at
    }
  end
end
