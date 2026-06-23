defmodule CodexPooler.Gateway.Routing.SavedResetAutoRedeem do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.QuotaRefresh.{Executor, Plan}
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Quotas.WindowClassifier
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @max_weekly_reset_seconds 7 * 24 * 60 * 60 + 60 * 60

  @spec maybe_redeem_after_quota_exhaustion(term(), map(), :required | :optional) :: term()
  def maybe_redeem_after_quota_exhaustion(result, refresh_plan, quota_mode)

  def maybe_redeem_after_quota_exhaustion(
        {:error, %{code: code} = error} = result,
        refresh_plan,
        :required
      )
      when code in ["quota_exhausted", :quota_exhausted] and is_map(refresh_plan) do
    if all_candidates_excluded_only_by_weekly_exhaustion?(error, refresh_plan) do
      maybe_redeem_candidate(result, refresh_plan)
    else
      result
    end
  end

  def maybe_redeem_after_quota_exhaustion(result, _refresh_plan, _quota_mode), do: result

  @spec maybe_redeem_before_quota_exhaustion(term(), map(), :required | :optional) :: term()
  def maybe_redeem_before_quota_exhaustion(result, refresh_plan, quota_mode)

  def maybe_redeem_before_quota_exhaustion(
        {:ok, _candidates, _decision} = result,
        refresh_plan,
        :required
      )
      when is_map(refresh_plan) do
    maybe_redeem_threshold_candidate(result, refresh_plan)
  end

  def maybe_redeem_before_quota_exhaustion(
        {:ok, _candidates, _decision, %RouteState{}} = result,
        refresh_plan,
        :required
      )
      when is_map(refresh_plan) do
    maybe_redeem_threshold_candidate(result, refresh_plan)
  end

  def maybe_redeem_before_quota_exhaustion(result, _refresh_plan, _quota_mode), do: result

  defp maybe_redeem_candidate(result, refresh_plan) do
    refresh_plan
    |> candidate_order()
    |> Enum.find(&redeemable_candidate?/1)
    |> case do
      {assignment, identity} ->
        redeem_and_refilter(result, refresh_plan, assignment, identity)

      nil ->
        result
    end
  end

  defp maybe_redeem_threshold_candidate(result, refresh_plan) do
    candidates = candidate_order(refresh_plan)

    candidates
    |> Enum.find(&threshold_redeemable_candidate?(&1, candidates))
    |> case do
      {assignment, identity} ->
        redeem_and_refilter(result, refresh_plan, assignment, identity)

      nil ->
        result
    end
  end

  defp redeem_and_refilter(result, refresh_plan, assignment, identity) do
    case SavedResetRedemption.redeem(assignment,
           trigger_kind: "gateway_auto",
           receive_timeout: 15_000
         ) do
      {:ok, %{applied?: true, code: code}} ->
        log_redemption(assignment, identity, "gateway_auto", code, true)
        refilter_after_redemption(result, refresh_plan)

      {:ok, %{applied?: applied?, code: code}} ->
        log_redemption(assignment, identity, "gateway_auto", code, applied?)
        result

      {:error, reason} ->
        log_redemption(assignment, identity, "gateway_auto", safe_reason(reason), false)
        result
    end
  rescue
    exception in [DBConnection.ConnectionError, Ecto.QueryError, Postgrex.Error] ->
      log_redemption(assignment, identity, "gateway_auto", safe_reason(exception), false)
      result
  end

  defp refilter_after_redemption(
         result,
         %{filter_input: %CandidateEligibility.FilterInput{} = input} = plan
       ) do
    case Map.get(plan, :route_state) do
      %RouteState{} = route_state ->
        refreshed_route_state = RouteState.refresh_quota_window_snapshots(route_state)

        case Plan.filter_eligible_candidates(input, refreshed_route_state) do
          {:refreshable_quota, remaining_plan} ->
            Executor.refresh_stale_candidates(remaining_plan)

          {:ok, candidates, decision} ->
            {:ok, candidates, decision, refreshed_route_state}
        end

      _no_route_state ->
        case Plan.filter_eligible_candidates(input) do
          {:refreshable_quota, remaining_plan} ->
            Executor.refresh_stale_candidates(remaining_plan)

          {:ok, candidates, decision} ->
            {:ok, candidates, decision}
        end
    end
  rescue
    exception in [DBConnection.ConnectionError, Ecto.QueryError, Postgrex.Error] ->
      Logger.warning("saved reset quota refilter failed reason=#{safe_reason(exception)}")

      result
  end

  defp all_candidates_excluded_only_by_weekly_exhaustion?(error, refresh_plan)
       when is_map(error) do
    exclusions = Map.get(error, :candidate_exclusions) || Map.get(error, "candidate_exclusions")

    candidate_keys =
      refresh_plan
      |> candidate_order()
      |> Enum.map(&candidate_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    exclusion_keys =
      exclusions
      |> List.wrap()
      |> Enum.map(&exclusion_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    MapSet.size(candidate_keys) > 0 and MapSet.equal?(candidate_keys, exclusion_keys) and
      Enum.all?(List.wrap(exclusions), &weekly_account_exhaustion_exclusion?/1)
  end

  defp candidate_order(%{filter_input: %{candidates: candidates}}) when is_list(candidates),
    do: candidates

  defp candidate_order(%{refreshable_candidates: candidates}) when is_list(candidates),
    do: candidates

  defp candidate_order(_refresh_plan), do: []

  defp candidate_key(
         {%PoolUpstreamAssignment{id: assignment_id}, %UpstreamIdentity{id: identity_id}}
       )
       when is_binary(assignment_id) and is_binary(identity_id),
       do: {assignment_id, identity_id}

  defp candidate_key(_candidate), do: nil

  defp exclusion_key(exclusion) when is_map(exclusion) do
    assignment_id =
      Map.get(exclusion, :pool_upstream_assignment_id) ||
        Map.get(exclusion, "pool_upstream_assignment_id")

    identity_id =
      Map.get(exclusion, :upstream_identity_id) || Map.get(exclusion, "upstream_identity_id")

    if is_binary(assignment_id) and is_binary(identity_id), do: {assignment_id, identity_id}
  end

  defp exclusion_key(_exclusion), do: nil

  defp weekly_account_exhaustion_exclusion?(exclusion) when is_map(exclusion) do
    reasons = Map.get(exclusion, :reasons) || Map.get(exclusion, "reasons")

    is_list(reasons) and reasons != [] and
      Enum.all?(reasons, &weekly_account_exhaustion_reason?/1)
  end

  defp weekly_account_exhaustion_exclusion?(_exclusion), do: false

  defp weekly_account_exhaustion_reason?(reason) when is_map(reason) do
    reason_code = Map.get(reason, :reason_codes) || Map.get(reason, "reason_codes")

    reason_token(reason, :code) == "quota_weekly_exhausted" and
      reason_token(reason, :quota_key) == "account" and
      reason_token(reason, :window_kind) == "secondary" and
      reason_token(reason, :quota_scope) == "account" and
      reason_token(reason, :quota_family) == "account" and
      exhausted_only_reason_codes?(reason_code)
  end

  defp weekly_account_exhaustion_reason?(_reason), do: false

  defp exhausted_only_reason_codes?(reason_codes) when is_list(reason_codes),
    do: reason_codes != [] and Enum.all?(reason_codes, &(&1 == "exhausted"))

  defp exhausted_only_reason_codes?(_reason_codes), do: false

  defp reason_token(reason, key), do: Map.get(reason, key) || Map.get(reason, Atom.to_string(key))

  defp redeemable_candidate?(
         {%PoolUpstreamAssignment{}, %UpstreamIdentity{} = identity} = candidate
       ) do
    policy = SavedResets.auto_policy(identity)

    saved_reset_available?(identity, policy) and redeemable_weekly_window?(candidate, policy)
  end

  defp redeemable_candidate?(_candidate), do: false

  defp threshold_redeemable_candidate?(
         {%PoolUpstreamAssignment{}, %UpstreamIdentity{} = identity},
         candidates
       )
       when is_list(candidates) do
    policy = SavedResets.auto_policy(identity)

    saved_reset_available?(identity, policy) and policy.trigger_mode == "threshold" and
      all_candidates_at_threshold?(candidates, policy)
  end

  defp threshold_redeemable_candidate?(_candidate, _candidates), do: false

  defp saved_reset_available?(%UpstreamIdentity{} = identity, policy) do
    snapshot = SavedResets.snapshot(identity)

    policy.enabled? and snapshot.available_count != nil and
      snapshot.available_count > policy.keep_credits and not snapshot.in_progress?
  end

  defp redeemable_weekly_window?(
         {%PoolUpstreamAssignment{}, %UpstreamIdentity{} = identity},
         policy
       ) do
    identity
    |> Windows.list_quota_windows()
    |> Enum.any?(fn window ->
      weekly_exhausted_window?(window, now()) and
        natural_reset_far_enough?(window.reset_at, policy.min_blocked_minutes)
    end)
  end

  defp all_candidates_at_threshold?([], _policy), do: false

  defp all_candidates_at_threshold?(candidates, policy) when is_list(candidates) do
    Enum.all?(candidates, &candidate_at_threshold?(&1, policy))
  end

  defp candidate_at_threshold?(
         {%PoolUpstreamAssignment{}, %UpstreamIdentity{} = identity},
         policy
       ) do
    identity
    |> Windows.list_quota_windows()
    |> Enum.any?(&weekly_pressure_window?(&1, policy))
  end

  defp candidate_at_threshold?(_candidate, _policy), do: false

  defp weekly_pressure_window?(window, policy) do
    timestamp = now()

    WindowClassifier.weekly_secondary?(window) and
      window.source_precision in ["observed", "authoritative"] and
      Windows.fresh_window?(window, timestamp) and match?(%DateTime{}, window.reset_at) and
      natural_reset_far_enough?(window.reset_at, policy.min_blocked_minutes) and
      used_percent_at_or_above?(window.used_percent, policy.quota_threshold_percent)
  end

  defp used_percent_at_or_above?(%Decimal{} = used_percent, threshold) when is_integer(threshold),
    do: Decimal.compare(used_percent, Decimal.new(threshold)) != :lt

  defp used_percent_at_or_above?(value, threshold)
       when is_number(value) and is_integer(threshold),
       do: value >= threshold

  defp used_percent_at_or_above?(_value, _threshold), do: false

  defp weekly_exhausted_window?(window, timestamp) do
    WindowClassifier.weekly_secondary?(window) and match?(%DateTime{}, window.reset_at) and
      used_percent_exhausted?(window.used_percent) and
      "exhausted" in Windows.routing_window_reason_codes(window, timestamp)
  end

  defp used_percent_exhausted?(%Decimal{} = used_percent),
    do: Decimal.compare(used_percent, Decimal.new(100)) != :lt

  defp used_percent_exhausted?(value) when is_number(value), do: value >= 100
  defp used_percent_exhausted?(_value), do: false

  defp natural_reset_far_enough?(%DateTime{} = reset_at, min_blocked_minutes) do
    seconds_until_reset = DateTime.diff(reset_at, now(), :second)

    seconds_until_reset >= min_blocked_minutes * 60 and
      seconds_until_reset <= @max_weekly_reset_seconds
  end

  defp natural_reset_far_enough?(_reset_at, _min_blocked_minutes), do: false

  defp log_redemption(assignment, identity, trigger_kind, code, applied?) do
    Logger.info(
      "saved reset auto redemption result " <>
        "pool_upstream_assignment_id=#{assignment.id} " <>
        "upstream_identity_id=#{identity.id} " <>
        "trigger_kind=#{trigger_kind} " <>
        "result_code=#{code} " <>
        "applied=#{applied?}"
    )
  end

  defp safe_reason(%{code: code}) when is_atom(code), do: Atom.to_string(code)
  defp safe_reason(%{code: code}) when is_binary(code), do: sanitize_token(code)
  defp safe_reason(%module{}) when is_atom(module), do: module |> Module.split() |> List.last()
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "unknown"

  defp sanitize_token(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 80)
    |> case do
      "" -> "unknown"
      token -> token
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
