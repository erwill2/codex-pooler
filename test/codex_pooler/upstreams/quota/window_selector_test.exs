defmodule CodexPooler.Upstreams.Quota.WindowSelectorTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector

  @as_of ~U[2026-07-09 15:45:00Z]

  test "prefers measured account evidence over a later zero-capacity usage outlier" do
    outlier =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(@as_of, 5, :hour),
        observed_at: DateTime.add(@as_of, 60, :second)
      )

    measured =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("6"),
        reset_at: DateTime.add(@as_of, 2, :hour),
        observed_at: @as_of
      )

    assert WindowSelector.best_account_window([outlier, measured], :primary_5h, @as_of) ==
             measured
  end

  test "keeps the only reset-bearing zero-capacity account evidence visible" do
    outlier =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(@as_of, 5, :hour)
      )

    assert WindowSelector.best_account_window([outlier], :primary_5h, @as_of) == outlier
  end

  test "prefers usable monthly primary over usable 5h primary for routing selection" do
    primary_5h =
      account_window(
        used_percent: Decimal.new("6"),
        reset_at: DateTime.add(@as_of, 2, :hour)
      )

    monthly =
      account_window(
        window_minutes: 43_200,
        active_limit: 4_018,
        credits: 3_817,
        used_percent: Decimal.new("5"),
        reset_at: DateTime.add(@as_of, 14, :day)
      )

    assert WindowSelector.best_account_primary_variant([primary_5h, monthly], @as_of) ==
             monthly
  end

  test "does not let an unusable monthly outlier hide a usable 5h primary" do
    primary_5h =
      account_window(
        used_percent: Decimal.new("6"),
        reset_at: DateTime.add(@as_of, 2, :hour)
      )

    monthly_outlier =
      account_window(
        window_minutes: 43_200,
        active_limit: nil,
        credits: 3_817,
        used_percent: Decimal.new("100"),
        reset_at: DateTime.add(@as_of, 14, :day),
        observed_at: DateTime.add(@as_of, 60, :second)
      )

    assert WindowSelector.best_account_primary_variant([monthly_outlier, primary_5h], @as_of) ==
             primary_5h
  end

  defp account_window(attrs) do
    observed_at = Keyword.get(attrs, :observed_at, @as_of)

    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "account",
          quota_scope: "account",
          quota_family: "account",
          window_kind: "primary",
          window_minutes: 300,
          source: "codex_usage_api",
          source_precision: "observed",
          freshness_state: "fresh",
          merge_precedence: 60,
          observed_at: observed_at,
          last_sync_at: observed_at,
          updated_at: observed_at,
          metadata: %{}
        ],
        attrs
      )
    )
  end
end
