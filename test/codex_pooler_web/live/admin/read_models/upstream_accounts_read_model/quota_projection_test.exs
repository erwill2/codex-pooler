defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjectionTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  test "account quota rows prefer measured evidence over zero-capacity usage outliers" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outlier =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(observed_at, 5, :hour),
        observed_at: DateTime.add(observed_at, 60, :second)
      )

    measured =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("6"),
        reset_at: DateTime.add(observed_at, 2, :hour),
        observed_at: observed_at
      )

    primary =
      [outlier, measured]
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))
      |> Enum.find(&(&1.key == :primary_5h))

    assert Decimal.equal?(primary.percent, Decimal.new("94"))
    assert primary.percent_value == 94
    assert primary.percent_label == "94%"
  end

  test "account quota rows still show not reported when only zero-capacity evidence exists" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outlier =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(observed_at, 5, :hour),
        observed_at: observed_at
      )

    primary =
      [outlier]
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil))
      |> Enum.find(&(&1.key == :primary_5h))

    assert primary.percent == nil
    assert primary.percent_value == 0
    assert primary.percent_label == "not reported"
  end

  defp account_window(attrs) do
    observed_at = Keyword.fetch!(attrs, :observed_at)

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
          last_sync_at: observed_at,
          updated_at: observed_at,
          metadata: %{}
        ],
        attrs
      )
    )
  end
end
