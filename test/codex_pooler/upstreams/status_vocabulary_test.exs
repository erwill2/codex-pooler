defmodule CodexPooler.Upstreams.StatusVocabularyTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "upstream identity exports helpers for every lifecycle status" do
    assert helper_values(UpstreamIdentity, [
             :pending_status,
             :active_status,
             :paused_status,
             :refresh_due_status,
             :refreshing_status,
             :refresh_failed_status,
             :reauth_required_status,
             :deleted_status,
             :disabled_status,
             :errored_status
           ]) == UpstreamIdentity.statuses()
  end

  test "pool assignment exports helpers for every lifecycle and routing status" do
    assert helper_values(PoolUpstreamAssignment, [
             :pending_status,
             :active_status,
             :paused_status,
             :refresh_due_status,
             :refreshing_status,
             :refresh_failed_status,
             :reauth_required_status,
             :deleted_status,
             :disabled_status,
             :errored_status
           ]) == PoolUpstreamAssignment.statuses()

    assert helper_values(PoolUpstreamAssignment, [
             :unknown_health_status,
             :active_health_status,
             :cooldown_health_status,
             :degraded_health_status,
             :disabled_health_status,
             :errored_health_status
           ]) == PoolUpstreamAssignment.health_statuses()

    assert helper_values(PoolUpstreamAssignment, [
             :eligible_status,
             :ineligible_status
           ]) == PoolUpstreamAssignment.eligibility_statuses()
  end

  defp helper_values(module, helpers) do
    Enum.map(helpers, &apply(module, &1, []))
  end
end
