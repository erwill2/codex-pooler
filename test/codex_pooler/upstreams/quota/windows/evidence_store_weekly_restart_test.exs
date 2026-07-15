defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreWeeklyRestartTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows

  # Production shape while the provider's anchored 5h windows are suspended
  # (announced as temporary on 2026-07-13): a restarted weekly account arrives
  # from the usage endpoint as a weak zero (no active limit or credits) whose
  # relative reset is recomputed at response time, so reset_at slides forward in
  # step with each observation. A cached or replayed body keeps a fixed reset_at
  # instead.

  @window_seconds 10_080 * 60

  defp identity! do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    identity
  end

  defp exhausted_row!(identity, observed_at, opts \\ []) do
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(observed_at, 5, :day))

    Windows.record_evidence(
      identity,
      %{
        quota_key: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("100"),
        reset_at: reset_at,
        observed_at: observed_at,
        last_sync_at: observed_at,
        source: "codex_usage_api",
        source_precision: "observed",
        quota_scope: "account",
        quota_family: "account",
        freshness_state: "fresh"
      },
      observed_at
    )
  end

  defp floating_zero(observed_at, opts \\ []) do
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(observed_at, @window_seconds, :second))

    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("0"),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      metadata: %{"reset_after_seconds" => @window_seconds}
    }
  end

  defp account_row(identity) do
    Repo.one(
      from w in AccountQuotaWindow,
        where:
          w.upstream_identity_id == ^identity.id and w.quota_key == "account" and
            w.window_kind == "secondary" and w.source == "codex_usage_api"
    )
  end

  defp model_weekly(observed_at, used_percent, opts \\ []) do
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(observed_at, @window_seconds, :second))

    %{
      quota_key: "codex_spark",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(used_percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-5.3-codex-spark",
      freshness_state: "fresh",
      metadata: %{"reset_after_seconds" => @window_seconds}
    }
  end

  defp model_weekly_row(identity) do
    Repo.one(
      from w in AccountQuotaWindow,
        where:
          w.upstream_identity_id == ^identity.id and w.quota_key == "codex_spark" and
            w.window_kind == "secondary" and w.source == "codex_usage_api"
    )
  end

  defp spark_weekly_payload(used_percent, reset_at) do
    %{
      "additional_rate_limits" => [
        %{
          "limit_name" => "GPT-5.3-Codex-Spark",
          "metered_feature" => "codex_bengalfox",
          "model" => "gpt-5.3-codex-spark",
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => used_percent,
              "limit_window_seconds" => @window_seconds,
              "reset_after_seconds" => @window_seconds,
              "reset_at" => DateTime.to_iso8601(reset_at)
            }
          }
        }
      ]
    }
  end

  defp record_spark_payload!(identity, payload, observed_at) do
    assert {:ok, windows} = Windows.codex_usage_quota_windows_from_payload(payload, observed_at)

    assert [spark_weekly] =
             Enum.filter(
               windows,
               &(&1.quota_key == "codex_spark" and &1.window_kind == "secondary")
             )

    assert spark_weekly.quota_scope == "model"
    assert spark_weekly.metadata["reset_after_seconds"] == @window_seconds
    assert {:ok, row} = Windows.record_evidence(identity, spark_weekly, observed_at)
    row
  end

  test "sliding live restart observations converge an exhausted weekly account" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = exhausted_row!(identity, t0)

    # First live zero: quarantined, but tracked as a restart candidate.
    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t1), t1)
    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("100")) == :eq

    # Second live zero after the confirmation span, reset advanced in step with
    # observation time: the restart is confirmed and the row converges to 0%.
    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t2), t2)
    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
    assert DateTime.compare(row.observed_at, t2) == :eq
  end

  test "a cached same-cycle body never clears the exhausted row" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    # Existing exhausted cycle resets in 5 days.
    assert {:ok, _row} = exhausted_row!(identity, t0)

    # A cached/replayed body carries the OLD cycle's reset: a zero that claims
    # the account restarted while still pointing at the current cycle's reset
    # is contradictory and must stay quarantined no matter how often it repeats.
    same_cycle_reset = DateTime.add(t0, 5, :day)
    t1 = DateTime.add(t0, 300, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t1, reset_at: same_cycle_reset), t1)

    t2 = DateTime.add(t1, 240, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t2, reset_at: same_cycle_reset), t2)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("100")) == :eq
  end

  test "a zero inside the confirmation span keeps waiting without resetting the clock" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = exhausted_row!(identity, t0)

    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t1), t1)

    # One minute later: consistent but span not reached — still 100%.
    t2 = DateTime.add(t1, 60, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t2), t2)
    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("100")) == :eq

    # Two more minutes (3 minutes after the FIRST candidate): confirmed. If the
    # intermediate observation had replaced the candidate, the span would never
    # be reached under minute-by-minute reconciliation.
    t3 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t3), t3)
    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
  end

  test "anchored zeros converge once the exhausted cycle's own reset time has passed" do
    # Future-proof for the anchored 5h shape returning: the reset does not
    # slide, but the canonical itself declared the cycle over, so a candidate-
    # confirmed zero across the span converges it.
    t0 = DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:microsecond)
    identity = identity!()
    # The exhausted row's own reset passed an hour ago.
    assert {:ok, _row} = exhausted_row!(identity, t0, reset_at: DateTime.add(t0, 1, :hour))

    t1 = DateTime.utc_now() |> DateTime.add(-6, :minute) |> DateTime.truncate(:microsecond)
    anchored_reset = DateTime.add(t1, @window_seconds, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t1, reset_at: anchored_reset), t1)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("100")) == :eq

    t2 = DateTime.add(t1, 240, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t2, reset_at: anchored_reset), t2)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
  end

  test "a forward-anchored new cycle converges while the exhausted cycle has not ended" do
    # Production shape once the restarted window anchors (first request of the
    # new cycle, often from another deployment sharing the account): the reset
    # is fixed BEYOND the exhausted row's own reset. Only the provider can mint
    # that anchor after the new cycle began, so a zero holding the same forward
    # anchor across the span converges even though nothing slides.
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    # Existing exhausted cycle would reset in 5 days.
    assert {:ok, _row} = exhausted_row!(identity, t0)

    t1 = DateTime.add(t0, 300, :second)
    forward_anchor = DateTime.add(t1, @window_seconds, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t1, reset_at: forward_anchor), t1)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("100")) == :eq

    # Same anchor one minute later: span not reached, candidate must be kept.
    t2 = DateTime.add(t1, 60, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t2, reset_at: forward_anchor), t2)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("100")) == :eq

    # Same anchor past the confirmation span: the new cycle is confirmed.
    t3 = DateTime.add(t1, 240, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t3, reset_at: forward_anchor), t3)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
    assert DateTime.compare(row.reset_at, forward_anchor) == :eq
  end

  test "a non-exhausted row is untouched by the restart path" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               Map.put(floating_zero(t0), :used_percent, Decimal.new("40")),
               t0
             )

    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t1), t1)

    # Pre-existing semantics for non-exhausted rows apply; nothing crashes and
    # the row still exists with a valid percent.
    row = account_row(identity)
    assert row
  end

  test "sliding model weekly zeros become explicitly floating after confirmation" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    stale_reset = DateTime.add(t0, 3, :day)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t0, "0", reset_at: stale_reset),
               t0
             )

    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t1, "0"), t1)

    row = model_weekly_row(identity)
    assert DateTime.compare(row.reset_at, stale_reset) == :eq
    refute row.metadata["reset_state"] == "floating"

    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t2, "0"), t2)

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(row.used_percent, Decimal.new("0"))
    assert DateTime.compare(row.reset_at, DateTime.add(t2, @window_seconds, :second)) == :eq
    assert DateTime.compare(row.observed_at, t2) == :eq
  end

  test "confirmed floating model weekly zero clears prior-cycle usage" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    stale_reset = DateTime.add(t0, 3, :day)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: stale_reset),
               t0
             )

    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t1, "0"), t1)
    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t2, "0"), t2)

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(row.used_percent, Decimal.new("0"))
  end

  test "cached model weekly zero never becomes floating or clears prior usage" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_reset = DateTime.add(t0, 3, :day)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: fixed_reset),
               t0
             )

    for offset <- [300, 540] do
      observed_at = DateTime.add(t0, offset, :second)

      assert {:ok, _row} =
               Windows.record_evidence(
                 identity,
                 model_weekly(observed_at, "0", reset_at: fixed_reset),
                 observed_at
               )
    end

    row = model_weekly_row(identity)
    refute row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, fixed_reset) == :eq
  end

  test "positive model usage anchors a previously floating weekly window" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()

    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t0, "0"), t0)

    t1 = DateTime.add(t0, 60, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t1, "0"), t1)
    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t2, "0"), t2)
    assert model_weekly_row(identity).metadata["reset_state"] == "floating"

    anchored_reset = DateTime.add(t2, @window_seconds, :second)
    t3 = DateTime.add(t2, 60, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t3, "2", reset_at: anchored_reset),
               t3
             )

    row = model_weekly_row(identity)
    refute Map.has_key?(row.metadata, "reset_state")
    assert Decimal.equal?(row.used_percent, Decimal.new("2"))
    assert DateTime.compare(row.reset_at, anchored_reset) == :eq
  end

  test "parsed Spark payload requires a moving absolute reset before marking it floating" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_reset = DateTime.add(t0, 3, :day)

    record_spark_payload!(identity, spark_weekly_payload(64, fixed_reset), t0)

    cached_zero = spark_weekly_payload(0, fixed_reset)

    for offset <- [300, 540] do
      observed_at = DateTime.add(t0, offset, :second)
      record_spark_payload!(identity, cached_zero, observed_at)
    end

    cached_row = model_weekly_row(identity)
    refute cached_row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(cached_row.used_percent, Decimal.new("64"))
    assert DateTime.compare(cached_row.reset_at, fixed_reset) == :eq

    t3 = DateTime.add(t0, 600, :second)

    record_spark_payload!(
      identity,
      spark_weekly_payload(0, DateTime.add(t3, @window_seconds)),
      t3
    )

    t4 = DateTime.add(t3, 240, :second)
    moving_reset = DateTime.add(t4, @window_seconds)
    record_spark_payload!(identity, spark_weekly_payload(0, moving_reset), t4)

    live_row = model_weekly_row(identity)
    assert live_row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(live_row.used_percent, Decimal.new("0"))
    assert DateTime.compare(live_row.reset_at, moving_reset) == :eq
  end
end
