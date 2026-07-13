defmodule CodexPooler.Alerts.PoolServingRiskTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [primary_quota_window_attrs: 1]

  alias CodexPooler.Alerts
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "pool_no_usable_assignments matches when no assignment can route" do
    timestamp = now()
    pool = pool_fixture()
    upstream_assignment_fixture(pool)

    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert [%{action: :match, match_attrs: match}] = Alerts.evaluate_rule(rule, at: timestamp)
    assert match.scope_type == "pool"
    assert match.pool_id == pool.id
    assert match.safe_evidence_snapshot["reason_code"] == "no_usable_assignments"
    assert match.safe_evidence_snapshot["assignment_count"] == 1
    assert match.safe_evidence_snapshot["enabled_assignment_count"] == 1
    assert match.safe_evidence_snapshot["usable_assignment_count"] == 0
  end

  test "pool_low_usable_assignments matches below configured minimum and clears at or above it" do
    timestamp = now()
    pool = pool_fixture()
    %{identity: usable_identity} = upstream_assignment_fixture(pool)
    upstream_assignment_fixture(pool)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(usable_identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("25"),
                 credits: 75,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    warning_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_low_usable_assignments",
        severity: "warning",
        min_usable_assignments: 2
      )

    assert [%{action: :match, match_attrs: match}] =
             Alerts.evaluate_rule(warning_rule, at: timestamp)

    assert match.severity == "warning"
    assert match.safe_evidence_snapshot["reason_code"] == "low_usable_assignments"
    assert match.safe_evidence_snapshot["usable_assignment_count"] == 1
    assert match.safe_evidence_snapshot["min_usable_assignments"] == 2

    clear_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_low_usable_assignments",
        min_usable_assignments: 1
      )

    assert [%{action: :clear}] = Alerts.evaluate_rule(clear_rule, at: timestamp)
  end

  test "pool_all_assignments_in_state matches all enabled assignments and ignores disabled ones" do
    timestamp = now()
    pool = pool_fixture()
    %{identity: exhausted_identity} = upstream_assignment_fixture(pool)

    upstream_assignment_fixture(pool, %{
      assignment_status: "disabled",
      health_status: "disabled",
      eligibility_status: "ineligible"
    })

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(exhausted_identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("100"),
                 credits: 0,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "exhausted",
        severity: "critical"
      )

    assert [%{action: :match, match_attrs: match}] = Alerts.evaluate_rule(rule, at: timestamp)
    assert match.safe_evidence_snapshot["reason_code"] == "exhausted"
    assert match.safe_evidence_snapshot["enabled_assignment_count"] == 1
    assert match.safe_evidence_snapshot["state_counts"] == %{"exhausted" => 1}
  end

  test "pool serving-risk predicates clear when usable assignments are healthy" do
    timestamp = now()
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("10"),
                 credits: 90,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    no_usable_rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    all_missing_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "missing_evidence"
      )

    assert [%{action: :clear}] = Alerts.evaluate_rule(no_usable_rule, at: timestamp)
    assert [%{action: :clear}] = Alerts.evaluate_rule(all_missing_rule, at: timestamp)
  end

  test "reauth-required takes priority over fresh usable quota in pool serving risk" do
    timestamp = now()
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{identity_status: "reauth_required"})

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("10"),
                 credits: 90,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    reauth_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "reauth_required"
      )

    no_usable_rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert [%{action: :match, match_attrs: reauth_match}] =
             Alerts.evaluate_rule(reauth_rule, at: timestamp)

    assert reauth_match.safe_evidence_snapshot["state_counts"] == %{"reauth_required" => 1}

    assert [%{action: :match, match_attrs: no_usable_match}] =
             Alerts.evaluate_rule(no_usable_rule, at: timestamp)

    assert no_usable_match.safe_evidence_snapshot["usable_assignment_count"] == 0
  end

  test "reauth-required takes priority over stale quota in pool serving risk" do
    timestamp = now()
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{identity_status: "reauth_required"})

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 freshness_state: "stale",
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    reauth_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "reauth_required"
      )

    stale_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "stale"
      )

    assert [%{action: :match, match_attrs: reauth_match}] =
             Alerts.evaluate_rule(reauth_rule, at: timestamp)

    assert reauth_match.safe_evidence_snapshot["reason_code"] == "reauth_required"
    assert [%{action: :clear}] = Alerts.evaluate_rule(stale_rule, at: timestamp)
  end

  test "fresh recovered quota clears reauth serving-risk predicates" do
    timestamp = now()
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{identity_status: "reauth_required"})

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("20"),
                 credits: 80,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    reauth_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "reauth_required"
      )

    no_usable_rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert [%{action: :match}] = Alerts.evaluate_rule(reauth_rule, at: timestamp)
    assert [%{action: :match}] = Alerts.evaluate_rule(no_usable_rule, at: timestamp)

    identity
    |> UpstreamIdentity.changeset(%{status: "active", disabled_at: nil})
    |> Repo.update!()

    assert [%{action: :clear}] = Alerts.evaluate_rule(reauth_rule, at: timestamp)
    assert [%{action: :clear}] = Alerts.evaluate_rule(no_usable_rule, at: timestamp)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
