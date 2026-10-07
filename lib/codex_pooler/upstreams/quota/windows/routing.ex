defmodule CodexPooler.Upstreams.Quota.Windows.Routing do
  @moduledoc false

  alias CodexPooler.Quotas.{Evidence, ModelWeeklyResetSemantics, WindowClassifier}
  alias CodexPooler.Upstreams.Quota

  alias CodexPooler.Upstreams.Quota.{
    AccountAvailabilityStore,
    RoutingQuotaSnapshot,
    WindowSelector
  }

  @fresh "fresh"
  @account_quota_key "account"

  @spec selection_data_from_windows([Quota.AccountQuotaWindow.t()], keyword()) :: map()
  def selection_data_from_windows(windows, opts \\ []) when is_list(windows) do
    timestamp = Keyword.get(opts, :at, now())

    if reserve_model_request?(opts) do
      selection_data_for_reserve(windows, timestamp)
    else
      routing_windows =
        windows
        |> Enum.filter(&window_in_model_scope?(&1, opts))
        |> reject_superseded_primary_windows(timestamp)
        |> WindowSelector.logical_windows(timestamp)
        |> select_current_account_primary_variant(timestamp)

      ordinary = %{
        windows: windows,
        routing_windows: routing_windows,
        primary: WindowSelector.best_account_primary_variant(routing_windows, timestamp),
        secondary:
          WindowSelector.best_account_window(routing_windows, :weekly_secondary, timestamp),
        fresh_windows: Enum.filter(routing_windows, &fresh_window?(&1, timestamp)),
        blocked_windows: Enum.reject(routing_windows, &usable_window?(&1, timestamp)),
        usable?: Enum.any?(routing_windows, &usable_window?(&1, timestamp))
      }

      if not routing_quota_eligible?(routing_quota_state(ordinary, timestamp)) and
           luna_reserve_supported?(opts) do
        reserve = selection_data_for_reserve(windows, timestamp)
        if reserve.usable?, do: reserve, else: ordinary
      else
        ordinary
      end
    end
  end

  @spec eligibility_from_windows([Quota.AccountQuotaWindow.t()], keyword()) :: map()
  def eligibility_from_windows(windows, opts \\ []) when is_list(windows) do
    windows
    |> selection_data_from_windows(opts)
    |> eligibility_from_selection(opts)
  end

  @spec eligibility_from_snapshot(RoutingQuotaSnapshot.t(), keyword()) :: map()
  def eligibility_from_snapshot(%RoutingQuotaSnapshot{} = snapshot, opts \\ [])
      when is_list(opts) do
    opts = Keyword.put(opts, :at, snapshot.as_of)
    raw_windows = RoutingQuotaSnapshot.time_visible_raw_windows(snapshot)
    ordinary = eligibility_from_windows(raw_windows, opts)

    cond do
      not (reserve_model_request?(opts) or ordinary.selection[:reserve_mode?] == true) and
          AccountAvailabilityStore.blocked?(
            snapshot.availability,
            snapshot.credential_epoch,
            snapshot.as_of
          ) ->
        availability_exclusion(:blocked, ordinary.selection)

      ordinary.eligible? ->
        ordinary

      provider_permission_usable?(snapshot, ordinary.selection) ->
        %{
          ordinary
          | eligible?: true,
            routing_state: :provider_available,
            exclusions: []
        }

      true ->
        availability_fallback(snapshot, raw_windows, ordinary)
    end
  end

  # Preserve the reported percentage. A current full usage observation may
  # attest account capacity, but cannot override another window's authority.
  defp provider_permission_usable?(snapshot, selection) do
    fresh_available?(snapshot) and selection.blocked_windows != [] and
      Enum.all?(selection.blocked_windows, &permission_overrides_percent?(&1, snapshot))
  end

  defp permission_overrides_percent?(
         %Quota.AccountQuotaWindow{
           quota_scope: "account",
           source: "codex_usage_api",
           observed_at: observed_at,
           metadata: %{"rate_limit_allowed" => true, "rate_limit_reached" => false}
         } = window,
         %RoutingQuotaSnapshot{availability: %{observed_at: observed_at}} = snapshot
       ) do
    window_reason_codes(window, snapshot.as_of) == ["exhausted"] and
      exhausted_by_used_percent?(window)
  end

  defp permission_overrides_percent?(_window, _snapshot), do: false

  defp availability_fallback(snapshot, raw_windows, ordinary) do
    windowless_evidence? =
      windowless_snapshot_evidence?(snapshot, raw_windows, ordinary.selection)

    cond do
      current_available?(snapshot) and no_raw_account_windows?(raw_windows) and
          applicable_unusable_windows(ordinary.selection, snapshot.as_of) != [] ->
        applicable_unusable_exclusion(ordinary.selection, snapshot.as_of)

      windowless_evidence? and fresh_available?(snapshot) ->
        windowless_available_result(ordinary.selection)

      windowless_evidence? and stale_current_available?(snapshot) ->
        availability_exclusion(:not_fresh, ordinary.selection)

      true ->
        ordinary
    end
  end

  defp windowless_snapshot_evidence?(snapshot, raw_windows, selection) do
    windowless_eligible_evidence?(raw_windows, selection, snapshot.as_of) and
      not account_window_from_availability?(snapshot)
  end

  defp account_window_from_availability?(%RoutingQuotaSnapshot{
         raw_windows: windows,
         availability: %{observed_at: observed_at}
       }) do
    Enum.any?(windows, fn window ->
      window.quota_scope == "account" and window.source == "codex_usage_api" and
        window.observed_at == observed_at
    end)
  end

  defp account_window_from_availability?(_snapshot), do: false

  defp windowless_available_result(selection) do
    %{
      eligible?: true,
      routing_state: :windowless_provider_available,
      warnings: [],
      selection: selection,
      exclusions: []
    }
  end

  @spec eligibility_from_selection(map(), keyword()) :: map()
  def eligibility_from_selection(selection, opts) when is_map(selection) and is_list(opts) do
    timestamp = Keyword.get(opts, :at, now())
    routing_state = routing_quota_state(selection, timestamp)

    eligible? = routing_quota_eligible?(routing_state)

    %{
      eligible?: eligible?,
      routing_state: routing_state,
      warnings: quota_routing_warnings(selection, timestamp, routing_state),
      selection: selection,
      exclusions: quota_routing_exclusions(selection, timestamp, eligible?)
    }
  end

  @doc """
  Rejects primary windows whose shape the provider stopped reporting.

  A primary window is superseded when it is no longer fresh (or already
  expired) while another window in the same quota group kept syncing for at
  least one full freshness TTL after the primary froze. That evidence gap
  proves the provider still reports quota for the group but dropped this
  primary shape (for example replacing the 5h account window with a weekly
  primary slot), so the frozen row must stop blocking selection, routing, and
  weekly-only probing. If the provider reintroduces the shape, new evidence
  refreshes the row and it becomes selectable again.
  """
  @spec reject_superseded_primary_windows([Quota.AccountQuotaWindow.t()], DateTime.t()) ::
          [Quota.AccountQuotaWindow.t()]
  def reject_superseded_primary_windows(windows, timestamp \\ now()) when is_list(windows) do
    Enum.reject(windows, fn window ->
      if superseded_window?(window, windows, timestamp) do
        :telemetry.execute(
          [:codex_pooler, :quota, :cycle, :decision],
          %{count: 1},
          %{
            scope: quota_scope(window),
            decision: :superseded_primary_rejected,
            source: source_class(window)
          }
        )

        true
      else
        false
      end
    end)
  end

  defp quota_scope(%Quota.AccountQuotaWindow{quota_scope: scope})
       when scope in ["model", "upstream_model"],
       do: "model"

  defp quota_scope(%Quota.AccountQuotaWindow{}), do: "account"

  defp source_class(%Quota.AccountQuotaWindow{source: "codex_usage_api"}), do: "provider_usage"

  defp source_class(%Quota.AccountQuotaWindow{source: source})
       when source in [
              "runtime",
              "rate_limit",
              "response_header",
              "codex_response_headers",
              "codex_rate_limit_event",
              "codex_rate_limit_error"
            ],
       do: "runtime"

  defp source_class(%Quota.AccountQuotaWindow{}), do: "unknown"

  defp superseded_window?(window, windows, timestamp) do
    superseded_primary_window?(window, windows, timestamp) or
      superseded_runtime_window?(window, windows, timestamp)
  end

  defp superseded_primary_window?(
         %Quota.AccountQuotaWindow{window_kind: "primary"} = window,
         windows,
         timestamp
       ) do
    (not fresh_window?(window, timestamp) or Evidence.expired?(window, timestamp)) and
      Enum.any?(windows, &newer_quota_group_sibling?(&1, window, timestamp))
  end

  defp superseded_primary_window?(_window, _windows, _timestamp), do: false

  defp superseded_runtime_window?(
         %Quota.AccountQuotaWindow{source: source} = window,
         windows,
         timestamp
       )
       when source in [
              "codex_response_headers",
              "codex_rate_limit_event",
              "codex_rate_limit_error"
            ] do
    (not fresh_window?(window, timestamp) or Evidence.expired?(window, timestamp)) and
      Enum.any?(windows, fn other ->
        quota_group_key(other) == quota_group_key(window) and
          other.source == "codex_usage_api" and fresh_window?(other, timestamp) and
          match?(%DateTime{}, other.observed_at) and match?(%DateTime{}, window.observed_at) and
          DateTime.compare(other.observed_at, window.observed_at) == :gt
      end)
  end

  defp superseded_runtime_window?(_window, _windows, _timestamp), do: false

  defp newer_quota_group_sibling?(sibling, window, timestamp) do
    sibling != window and quota_group_key(sibling) == quota_group_key(window) and
      sync_gap_at_least_freshness_ttl?(sibling, window, timestamp)
  end

  defp quota_group_key(%Quota.AccountQuotaWindow{} = window) do
    {scope, family, model, upstream_model, quota_key, _window_kind, _window_minutes} =
      WindowSelector.logical_key(window)

    {scope, family, model, upstream_model, quota_key}
  end

  defp sync_gap_at_least_freshness_ttl?(sibling, window, timestamp) do
    with %DateTime{} = sibling_synced_at <- window_latest_evidence_at(sibling, timestamp),
         %DateTime{} = window_synced_at <- window_latest_evidence_at(window, timestamp) do
      DateTime.diff(sibling_synced_at, window_synced_at, :second) >=
        Evidence.freshness_ttl_seconds()
    else
      _missing_timestamps -> false
    end
  end

  defp window_latest_evidence_at(%Quota.AccountQuotaWindow{} = window, timestamp) do
    [window.observed_at, window.last_sync_at]
    |> Enum.filter(&(match?(%DateTime{}, &1) and DateTime.compare(&1, timestamp) != :gt))
    |> Enum.max(DateTime, fn -> nil end)
  end

  @spec fresh_window?(Quota.AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def fresh_window?(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    Evidence.current_freshness_state(window, timestamp) == @fresh
  end

  @spec usable_window?(Quota.AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def usable_window?(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    fresh_window?(window, timestamp) and not exhausted?(window) and
      Evidence.reset_bearing?(window) and
      not Evidence.expired?(window, timestamp)
  end

  @spec usable_window?(Quota.AccountQuotaWindow.t(), DateTime.t(), keyword()) :: boolean()
  def usable_window?(%Quota.AccountQuotaWindow{} = window, timestamp, opts) when is_list(opts) do
    usable_window?(window, timestamp) and window_in_model_scope?(window, opts)
  end

  @spec window_exclusion(Quota.AccountQuotaWindow.t(), DateTime.t()) :: map()
  def window_exclusion(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    %{
      code: "quota_window_unusable",
      reason_codes: window_reason_codes(window, timestamp),
      quota_key: window.quota_key,
      window_kind: window.window_kind,
      quota_scope: window.quota_scope,
      quota_family: window.quota_family,
      model: window.model,
      upstream_model: window.upstream_model,
      source: window.source,
      source_precision: window.source_precision,
      freshness_state: Evidence.current_freshness_state(window, timestamp),
      reset_at: iso8601_or_nil(window.reset_at)
    }
  end

  @spec window_reason_codes(Quota.AccountQuotaWindow.t(), DateTime.t()) :: [String.t()]
  def window_reason_codes(%Quota.AccountQuotaWindow{} = window, timestamp \\ now()) do
    []
    |> maybe_add_reason(not Evidence.reset_bearing?(window), "reset_missing")
    |> maybe_add_reason(Evidence.expired?(window, timestamp), "expired")
    |> maybe_add_reason(
      Evidence.current_freshness_state(window, timestamp) != @fresh,
      "not_fresh"
    )
    |> maybe_add_reason(exhausted?(window), "exhausted")
    |> case do
      [] -> ["unknown_unusable"]
      reasons -> Enum.reverse(reasons)
    end
  end

  defp routing_quota_state(%{reserve_mode?: true, usable?: true}, _timestamp),
    do: :weekly_only_probe

  defp routing_quota_state(%{reserve_mode?: true}, _timestamp),
    do: :blocked

  defp routing_quota_state(
         %{primary: %Quota.AccountQuotaWindow{}, blocked_windows: []},
         _timestamp
       ),
       do: :precise

  defp routing_quota_state(selection, timestamp) do
    cond do
      credit_backed_probe_selection?(selection, timestamp) -> :credit_backed_probe
      weekly_only_probe_selection?(selection, timestamp) -> :weekly_only_probe
      true -> :blocked
    end
  end

  defp routing_quota_eligible?(state)
       when state in [:precise, :credit_backed_probe, :weekly_only_probe],
       do: true

  defp routing_quota_eligible?(_state), do: false

  defp windowless_eligible_evidence?(raw_windows, selection, timestamp) do
    no_raw_account_windows?(raw_windows) and
      applicable_unusable_windows(selection, timestamp) == []
  end

  defp no_raw_account_windows?(raw_windows),
    do: not Enum.any?(raw_windows, &account_scoped_window?/1)

  defp applicable_unusable_windows(selection, timestamp) do
    Enum.reject(selection.routing_windows, &usable_window?(&1, timestamp))
  end

  defp account_scoped_window?(%Quota.AccountQuotaWindow{quota_scope: "account"}), do: true
  defp account_scoped_window?(%Quota.AccountQuotaWindow{}), do: false

  defp stale_current_available?(%RoutingQuotaSnapshot{
         availability: %AccountAvailabilityStore.Snapshot{
           state: :available,
           credential_epoch: epoch,
           observed_at: observed_at
         },
         credential_epoch: epoch,
         as_of: as_of
       }) do
    DateTime.compare(observed_at, as_of) != :gt and
      DateTime.compare(
        as_of,
        DateTime.add(observed_at, Evidence.freshness_ttl_seconds(), :second)
      ) == :gt
  end

  defp stale_current_available?(%RoutingQuotaSnapshot{}), do: false

  defp current_available?(%RoutingQuotaSnapshot{
         availability: %AccountAvailabilityStore.Snapshot{
           state: :available,
           credential_epoch: epoch
         },
         credential_epoch: epoch
       }),
       do: true

  defp current_available?(%RoutingQuotaSnapshot{}), do: false

  defp fresh_available?(%RoutingQuotaSnapshot{} = snapshot) do
    AccountAvailabilityStore.available?(
      snapshot.availability,
      snapshot.credential_epoch,
      snapshot.as_of
    )
  end

  defp applicable_unusable_exclusion(selection, timestamp) do
    %{
      eligible?: false,
      routing_state: :blocked,
      warnings: [],
      selection: selection,
      exclusions:
        Enum.map(
          applicable_unusable_windows(selection, timestamp),
          &window_exclusion(&1, timestamp)
        )
    }
  end

  defp availability_exclusion(reason, selection) when reason in [:blocked, :not_fresh] do
    reason_code = if reason == :blocked, do: "exhausted", else: "not_fresh"

    %{
      eligible?: false,
      routing_state: :blocked,
      warnings: [],
      selection: selection,
      exclusions: [
        %{
          code: "quota_window_unusable",
          message: "recorded quota evidence is not usable for routing",
          reason_codes: [reason_code],
          quota_key: "account",
          quota_scope: "account",
          quota_family: "account"
        }
      ]
    }
  end

  defp credit_backed_probe_selection?(
         %{secondary: %Quota.AccountQuotaWindow{} = secondary, blocked_windows: blocked_windows},
         timestamp
       ) do
    credit_backed_secondary_window?(secondary, timestamp) and
      Enum.any?(blocked_windows, &credit_backed_secondary_window?(&1, timestamp)) and
      Enum.all?(blocked_windows, &credit_backed_secondary_window?(&1, timestamp))
  end

  defp credit_backed_probe_selection?(_selection, _timestamp), do: false

  defp weekly_only_probe_selection?(
         %{primary: nil, secondary: %Quota.AccountQuotaWindow{} = secondary} = selection,
         timestamp
       ) do
    not Enum.any?(selection.blocked_windows, &weekly_probe_blocking_window?/1) and
      account_weekly_window?(secondary) and
      weekly_probe_usable_window?(secondary, timestamp)
  end

  defp weekly_only_probe_selection?(_selection, _timestamp), do: false

  # Model-scoped exhaustion must block the weekly probe for that model even
  # after the weekly-primary remap: the provider now reports model limits
  # (for example Spark) as weekly windows in the primary slot, normalized to
  # `secondary`, so an exhausted model weekly is the model's own quota being
  # spent — kind alone no longer identifies it.
  defp weekly_probe_blocking_window?(%Quota.AccountQuotaWindow{quota_scope: scope} = window)
       when scope in ["model", "upstream_model"] do
    window.window_kind == "primary" or
      (window.window_kind == "secondary" and window.window_minutes == 10_080 and
         exhausted?(window))
  end

  defp weekly_probe_blocking_window?(%Quota.AccountQuotaWindow{} = window),
    do: account_primary_window?(window)

  defp account_weekly_window?(%Quota.AccountQuotaWindow{} = window) do
    quota_scope = window.quota_scope || "account"
    quota_family = window.quota_family || "account"

    window.quota_key == @account_quota_key and quota_scope == "account" and
      quota_family in ["account", "secondary"] and window.window_kind == "secondary" and
      window.window_minutes == 10_080
  end

  defp weekly_probe_usable_window?(
         %Quota.AccountQuotaWindow{source_precision: source_precision} = window,
         timestamp
       )
       when source_precision in ["observed", "authoritative"] do
    Evidence.reset_bearing?(window) and not exhausted?(window) and
      not Evidence.expired?(window, timestamp)
  end

  defp weekly_probe_usable_window?(%Quota.AccountQuotaWindow{} = window, timestamp),
    do: usable_window?(window, timestamp)

  defp credit_backed_secondary_window?(%Quota.AccountQuotaWindow{} = window, timestamp) do
    account_weekly_window?(window) and fresh_window?(window, timestamp) and
      Evidence.reset_bearing?(window) and not Evidence.expired?(window, timestamp) and
      exhausted_by_used_percent?(window) and positive_credits?(window)
  end

  defp account_primary_window?(%Quota.AccountQuotaWindow{} = window) do
    WindowClassifier.primary_5h?(window) or WindowClassifier.monthly_primary?(window)
  end

  defp select_current_account_primary_variant(routing_windows, timestamp) do
    case routing_windows
         |> Enum.filter(&(account_primary_window?(&1) and usable_window?(&1, timestamp))) do
      [] ->
        routing_windows

      usable_primary_windows ->
        current_primary =
          WindowSelector.best_account_primary_variant(usable_primary_windows, timestamp)

        Enum.reject(routing_windows, fn window ->
          account_primary_window?(window) and window != current_primary
        end)
    end
  end

  defp quota_routing_warnings(%{reserve_mode?: true}, _timestamp, _state), do: []

  defp quota_routing_warnings(selection, _timestamp, :weekly_only_probe) do
    secondary = selection.secondary

    [
      %{
        code: "quota_account_primary_unknown",
        message:
          "weekly quota is usable, but upstream has not supplied account primary 5h quota evidence",
        quota_key: secondary.quota_key,
        window_kind: secondary.window_kind,
        quota_scope: secondary.quota_scope,
        quota_family: secondary.quota_family,
        source: secondary.source,
        source_precision: secondary.source_precision,
        freshness_state: secondary.freshness_state,
        reset_at: secondary.reset_at
      }
    ]
  end

  defp quota_routing_warnings(_selection, _timestamp, _state), do: []

  defp quota_routing_exclusions(_selection, _timestamp, true), do: []

  defp quota_routing_exclusions(%{reserve_mode?: true, secondary: nil}, _timestamp, false) do
    [
      %{
        code: "quota_reserve_missing",
        message: "upstream account does not have gpt-reserve quota"
      }
    ]
  end

  defp quota_routing_exclusions(
         %{reserve_mode?: true, secondary: %Quota.AccountQuotaWindow{} = secondary},
         timestamp,
         false
       ) do
    [quota_exhausted_exclusion(secondary, timestamp)]
  end

  defp quota_routing_exclusions(%{windows: []}, _timestamp, false) do
    [
      %{
        code: "quota_evidence_missing",
        message: "no quota evidence has been recorded for this upstream identity"
      }
    ]
  end

  defp quota_routing_exclusions(%{routing_windows: []}, _timestamp, false) do
    [
      %{
        code: "quota_evidence_out_of_scope",
        message: "recorded quota evidence does not match the requested model scope"
      }
    ]
  end

  defp quota_routing_exclusions(
         %{primary: nil, secondary: %Quota.AccountQuotaWindow{} = secondary},
         timestamp,
         false
       ) do
    if exhausted?(secondary) do
      [quota_exhausted_exclusion(secondary, timestamp)]
    else
      quota_primary_missing_exclusion()
    end
  end

  defp quota_routing_exclusions(%{primary: nil, routing_windows: [_ | _]}, _timestamp, false) do
    quota_primary_missing_exclusion()
  end

  defp quota_routing_exclusions(%{blocked_windows: blocked_windows}, timestamp, false)
       when is_list(blocked_windows) do
    case blocked_windows do
      [] ->
        [
          %{
            code: "quota_evidence_unusable",
            message: "recorded quota evidence is not usable for routing"
          }
        ]

      windows ->
        Enum.map(windows, &window_exclusion(&1, timestamp))
    end
  end

  defp quota_primary_missing_exclusion do
    [
      %{
        code: "quota_account_primary_missing",
        message: "account primary quota evidence is required for routing"
      }
    ]
  end

  defp quota_exhausted_exclusion(%Quota.AccountQuotaWindow{} = window, timestamp) do
    window
    |> window_exclusion(timestamp)
    |> Map.merge(%{
      code: "quota_weekly_exhausted",
      message: "weekly quota is exhausted until reset"
    })
  end

  defp window_in_model_scope?(%Quota.AccountQuotaWindow{} = window, opts) do
    if Keyword.get(opts, :account_only, false) do
      window.quota_scope == "account"
    else
      window_in_requested_scope?(window, opts)
    end
  end

  defp window_in_requested_scope?(
         %Quota.AccountQuotaWindow{quota_scope: "model"} = window,
         opts
       ) do
    if reserve_model_request?(opts) do
      reserve_window?(window)
    else
      case model_candidates(opts) do
        [] ->
          true

        candidates ->
          Enum.any?(candidates, fn candidate ->
            same_optional_token?(candidate, window.model) or
              same_optional_token?(candidate, window.upstream_model)
          end)
      end
    end
  end

  defp window_in_requested_scope?(
         %Quota.AccountQuotaWindow{quota_scope: "upstream_model"} = window,
         opts
       ) do
    if reserve_model_request?(opts) do
      false
    else
      case upstream_model_candidates(opts) do
        [] -> true
        candidates -> Enum.any?(candidates, &same_optional_token?(&1, window.upstream_model))
      end
    end
  end

  defp window_in_requested_scope?(%Quota.AccountQuotaWindow{} = window, opts) do
    if reserve_model_request?(opts) do
      reserve_window?(window)
    else
      true
    end
  end

  defp selection_data_for_reserve(windows, timestamp) do
    reserve_windows =
      windows
      |> Enum.filter(&reserve_window?/1)
      |> WindowSelector.logical_windows(timestamp)

    best_reserve =
      reserve_windows
      |> Enum.sort_by(
        fn w ->
          {
            if(fresh_window?(w, timestamp), do: 1, else: 0),
            if(reserve_usable_window?(w, timestamp), do: 1, else: 0),
            DateTime.to_unix(w.reset_at || ~U[1970-01-01 00:00:00Z])
          }
        end,
        :desc
      )
      |> List.first()

    usable? = best_reserve != nil and reserve_usable_window?(best_reserve, timestamp)

    blocked_windows =
      case best_reserve do
        nil -> []
        w -> if usable?, do: [], else: [w]
      end

    %{
      windows: windows,
      routing_windows: if(best_reserve, do: [best_reserve], else: []),
      primary: nil,
      secondary: best_reserve,
      fresh_windows:
        if(best_reserve && fresh_window?(best_reserve, timestamp), do: [best_reserve], else: []),
      blocked_windows: blocked_windows,
      usable?: usable?,
      reserve_mode?: true
    }
  end

  defp reserve_usable_window?(
         %Quota.AccountQuotaWindow{source_precision: source_precision} = window,
         timestamp
       )
       when source_precision in ["observed", "authoritative"] do
    Evidence.reset_bearing?(window) and not exhausted?(window) and
      reserve_window_valid_timing?(window, timestamp)
  end

  defp reserve_usable_window?(%Quota.AccountQuotaWindow{} = window, timestamp) do
    not exhausted?(window) and reserve_window_valid_timing?(window, timestamp)
  end

  defp reserve_window_valid_timing?(window, timestamp) do
    not Evidence.expired?(window, timestamp) or
      ModelWeeklyResetSemantics.classify(window) == :floating or
      zero_used_reserve_window?(window)
  end

  defp zero_used_reserve_window?(%Quota.AccountQuotaWindow{used_percent: %Decimal{} = percent}) do
    Decimal.compare(percent, Decimal.new(0)) == :eq
  end

  defp zero_used_reserve_window?(_), do: false

  defp reserve_window?(%Quota.AccountQuotaWindow{} = window) do
    window.quota_key in ["gpt_reserve", "gpt-reserve"] or
      window.model in ["gpt-reserve", "gpt_reserve"] or
      (window.quota_family == "codex_model" and window.quota_key == "gpt_reserve")
  end

  defp reserve_window?(_), do: false

  defp reserve_model_request?(opts) do
    Keyword.get(opts, :reserve_mode?, false) or
      Enum.any?(model_candidates(opts), &(&1 in ["gpt-reserve", "gpt_reserve"]))
  end

  defp luna_reserve_supported?(opts) do
    Keyword.get(opts, :reserve_mode?, false) or
      Keyword.get(opts, :reserve_fallback?, false) or
      (model_candidates(opts) != [] and not astra_model_request?(opts))
  end

  defp astra_model_request?(opts) do
    Enum.any?(model_candidates(opts), &(&1 in ["gpt-6-astra", "astra"]))
  end


  defp model_candidates(opts) do
    opts
    |> Keyword.take([:model, :requested_model, :catalog_model, :exposed_model_id])
    |> Keyword.values()
    |> Kernel.++(upstream_model_candidates(opts))
    |> Enum.map(&normalize_optional_quota_scope_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp upstream_model_candidates(opts) do
    opts
    |> Keyword.take([:upstream_model, :upstream_model_id])
    |> Keyword.values()
    |> Enum.map(&normalize_optional_quota_scope_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp same_optional_token?(left, right) do
    not is_nil(left) and left == normalize_optional_quota_scope_value(right)
  end

  defp normalize_optional_quota_scope_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> String.downcase(value)
    end
  end

  defp normalize_optional_quota_scope_value(_value), do: nil

  defp exhausted_by_used_percent?(%Quota.AccountQuotaWindow{
         used_percent: %Decimal{} = used_percent
       }) do
    Decimal.compare(used_percent, Decimal.new(100)) != :lt
  end

  defp exhausted_by_used_percent?(_window), do: false

  defp positive_credits?(%Quota.AccountQuotaWindow{credits: credits}) when is_integer(credits),
    do: credits > 0

  defp positive_credits?(_window), do: false

  defp exhausted?(%Quota.AccountQuotaWindow{credits: credits} = window)
       when is_integer(credits) and credits > 0 do
    if WindowClassifier.monthly_primary?(window),
      do: false,
      else: exhausted_by_used_percent?(window)
  end

  defp exhausted?(%Quota.AccountQuotaWindow{used_percent: %Decimal{}} = window) do
    exhausted_by_used_percent?(window)
  end

  defp exhausted?(%Quota.AccountQuotaWindow{active_limit: 0}), do: true
  defp exhausted?(%Quota.AccountQuotaWindow{credits: 0}), do: true
  defp exhausted?(_window), do: false

  defp maybe_add_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_add_reason(reasons, false, _reason), do: reasons

  defp iso8601_or_nil(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601_or_nil(_datetime), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
