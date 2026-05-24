defmodule CodexPooler.Gateway.Routing.BridgeRing do
  @moduledoc """
  DB-backed bridge-ring routing and affinity helpers for gateway dispatch.

  Runtime pre-dispatch and service orchestration prepare and filter candidate
  eligibility; this module orders the already-eligible route plan and records
  metadata-only affinity and demotion state.
  """

  import Ecto.Query

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeAffinity, BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Routing.BridgeRing.{Metadata, Status}
  alias CodexPooler.Gateway.Routing.RoutePlanInput
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{Pool, RoutingSettings}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @default_strategy "bridge_ring"
  @default_ring_size 3
  @demotion_seconds 60
  @affinity_conflict_target {:unsafe_fragment,
                             "(pool_id, api_key_id, model_identifier, affinity_kind, affinity_key_hash) WHERE status = 'active'"}
  @demotion_conflict_target {:unsafe_fragment,
                             "(pool_id, api_key_id, model_identifier, pool_upstream_assignment_id) WHERE status = 'active'"}

  @type candidate :: {PoolUpstreamAssignment.t(), UpstreamIdentity.t()}
  @type routing_auth :: Access.auth_context()
  @type affinity_context :: %{
          enabled?: boolean(),
          kind: String.t() | nil,
          key_hash: binary() | nil,
          seed: term(),
          row: BridgeAffinity.t() | nil,
          status: String.t(),
          fallback_reason: String.t() | nil,
          pool_id: Ecto.UUID.t(),
          api_key_id: Ecto.UUID.t(),
          model_identifier: String.t()
        }
  @type demotion_map :: %{optional(Ecto.UUID.t()) => BridgeDemotion.t()}
  @type route_plan :: %{
          strategy: String.t(),
          bridge_ring_size: pos_integer(),
          candidates: [candidate()],
          affinity: affinity_context(),
          demotions: demotion_map(),
          request_metadata: map(),
          selected_assignment_id: Ecto.UUID.t() | nil
        }
  @type routing_status :: %{
          settings: RoutingSettings.t() | nil,
          active_affinity_count: non_neg_integer(),
          active_demotion_count: non_neg_integer(),
          active_circuit_count: non_neg_integer(),
          recent_demotions: [BridgeDemotion.t()],
          recent_circuits: [RoutingCircuitState.t()]
        }

  @spec plan_route(
          routing_auth(),
          Model.t(),
          list(),
          RoutePlanInput.t(),
          RequestOptions.t()
        ) ::
          route_plan()
  def plan_route(auth, %Model{} = model, candidates, %RoutePlanInput{} = input, opts)
      when is_list(candidates) do
    settings = Pools.get_routing_settings(auth.pool) || default_settings(auth.pool.id)
    affinity = affinity_context(auth, model, input, opts, settings)
    demotions = active_demotions(auth, model, candidates)

    ordered =
      settings.routing_strategy
      |> strategy_order(candidates, model, affinity.seed || input.correlation_id)
      |> apply_affinity(affinity)
      |> apply_demotions(demotions)

    ring_size = max(settings.bridge_ring_size || @default_ring_size, 1)
    candidates = Enum.take(ordered, ring_size)
    selected = List.first(candidates)

    %{
      strategy: settings.routing_strategy,
      bridge_ring_size: ring_size,
      candidates: candidates,
      affinity: affinity,
      demotions: demotions,
      request_metadata: Metadata.request_metadata(settings, affinity, demotions, selected),
      selected_assignment_id: selected && elem(selected, 0).id
    }
  end

  @spec record_success(route_plan(), PoolUpstreamAssignment.t(), UpstreamIdentity.t()) :: :ok
  def record_success(%{affinity: affinity} = plan, assignment, identity) do
    now = now()

    if affinity.enabled? and affinity.key_hash do
      upsert_affinity!(plan, assignment, identity, now)
    end

    resolve_demotions!(plan, assignment, now)
    :ok
  end

  @spec record_failure(
          route_plan(),
          PoolUpstreamAssignment.t(),
          UpstreamIdentity.t(),
          term(),
          term()
        ) :: String.t()
  def record_failure(plan, assignment, identity, reason_code, request_id \\ nil) do
    reason_code = sanitized_reason_code(reason_code)
    now = now()

    upsert_demotion!(plan, assignment, identity, reason_code, request_id, now)

    if plan.affinity.enabled? and plan.affinity.key_hash do
      mark_affinity_miss!(plan, now)
    end

    reason_code
  end

  @spec attempt_metadata(
          route_plan(),
          PoolUpstreamAssignment.t(),
          UpstreamIdentity.t(),
          non_neg_integer()
        ) ::
          map()
  defdelegate attempt_metadata(plan, assignment, identity, rank), to: Metadata

  @spec selected_metadata(route_plan(), PoolUpstreamAssignment.t(), non_neg_integer()) :: map()
  defdelegate selected_metadata(plan, assignment, rank), to: Metadata

  @spec demotion_metadata(term()) :: map()
  defdelegate demotion_metadata(reason_code), to: Metadata

  @spec routing_status(Pool.t() | Ecto.UUID.t() | term()) :: routing_status()
  defdelegate routing_status(pool_or_id), to: Status

  defp strategy_order("deterministic_rotation", candidates, _model, seed) do
    rotate_candidates(candidates, seed)
  end

  defp strategy_order("least_recent_success", candidates, _model, seed) do
    latest_success = latest_success_by_assignment(candidates)

    Enum.sort_by(candidates, fn {assignment, _identity} ->
      {
        Map.get(latest_success, assignment.id) || ~U[1970-01-01 00:00:00Z],
        -rendezvous_score(seed, assignment.id)
      }
    end)
  end

  defp strategy_order("quota_first", candidates, %Model{} = model, seed) do
    Enum.sort_by(candidates, fn {assignment, identity} ->
      {
        -quota_headroom_score(identity, model),
        -rendezvous_score(seed, assignment.id)
      }
    end)
  end

  defp strategy_order(_strategy, candidates, _model, seed) do
    Enum.sort_by(candidates, fn {assignment, _identity} ->
      -rendezvous_score(seed, assignment.id)
    end)
  end

  # Reason: affinity selection intentionally compares all sticky routing inputs together.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp affinity_context(auth, model, %RoutePlanInput{} = input, opts, settings) do
    %{
      codex_session: codex_session,
      request_id: explicit_request_id,
      idempotency_key: idempotency_key
    } = affinity_request_context(opts)

    {enabled?, kind, key_value} =
      cond do
        codex_session && settings.sticky_websocket_sessions ->
          {true, "codex_session", codex_session.id}

        is_binary(idempotency_key) and idempotency_key != "" ->
          {true, "idempotency_key", idempotency_key}

        is_binary(explicit_request_id) and explicit_request_id != "" ->
          {true, "request_correlation", explicit_request_id}

        settings.sticky_http_sessions ->
          {true, "request_correlation", input.correlation_id}

        true ->
          {false, nil, nil}
      end

    key_hash = if enabled?, do: affinity_hash(auth, model, kind, key_value)
    affinity = if key_hash, do: active_affinity(auth, model, kind, key_hash)

    %{
      enabled?: enabled?,
      kind: kind,
      key_hash: key_hash,
      seed: key_value || input.correlation_id,
      row: affinity,
      status: affinity_status(enabled?, affinity),
      fallback_reason: nil,
      pool_id: auth.pool.id,
      api_key_id: auth.api_key.id,
      model_identifier: model.exposed_model_id
    }
  end

  defp affinity_request_context(%RequestOptions{} = request_options) do
    %{
      codex_session: request_options.continuity.codex_session,
      request_id: request_options.request_metadata.request_id,
      idempotency_key: request_options.request_metadata.idempotency_key
    }
  end

  defp affinity_hash(auth, model, kind, key_value) do
    canonical_key =
      [auth.pool.id, auth.api_key.id, model.exposed_model_id, kind, key_value]
      |> Enum.join(":")

    :crypto.hash(:sha256, canonical_key)
  end

  defp active_affinity(auth, model, kind, key_hash) do
    active_status = BridgeAffinity.active_status()

    Repo.one(
      from affinity in BridgeAffinity,
        where:
          affinity.pool_id == ^auth.pool.id and affinity.api_key_id == ^auth.api_key.id and
            affinity.model_identifier == ^model.exposed_model_id and
            affinity.affinity_kind == ^kind and
            affinity.affinity_key_hash == ^key_hash and affinity.status == ^active_status,
        limit: 1
    )
  end

  defp affinity_status(false, _affinity), do: "disabled"
  defp affinity_status(true, %BridgeAffinity{}), do: "hit"
  defp affinity_status(true, _affinity), do: "miss"

  defp apply_affinity(candidates, %{row: nil} = _affinity), do: candidates

  defp apply_affinity(candidates, %{row: %BridgeAffinity{} = affinity}) do
    {matched, rest} =
      Enum.split_with(candidates, fn {assignment, _identity} ->
        assignment.id == affinity.pool_upstream_assignment_id
      end)

    matched ++ rest
  end

  defp active_demotions(auth, model, candidates) do
    assignment_ids = Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)
    active_status = BridgeDemotion.active_status()
    now = now()

    Repo.all(
      from demotion in BridgeDemotion,
        where:
          demotion.pool_id == ^auth.pool.id and demotion.api_key_id == ^auth.api_key.id and
            demotion.model_identifier == ^model.exposed_model_id and
            demotion.pool_upstream_assignment_id in ^assignment_ids and
            demotion.status == ^active_status and
            (is_nil(demotion.demoted_until) or demotion.demoted_until > ^now)
    )
    |> Map.new(&{&1.pool_upstream_assignment_id, &1})
  end

  defp apply_demotions(candidates, demotions) when map_size(demotions) == 0, do: candidates

  defp apply_demotions(candidates, demotions) do
    {active, demoted} =
      Enum.split_with(candidates, fn {assignment, _identity} ->
        not Map.has_key?(demotions, assignment.id)
      end)

    active ++ demoted
  end

  defp upsert_affinity!(plan, assignment, identity, now) do
    metadata = %{"source" => "gateway_success"}

    on_conflict =
      from affinity in BridgeAffinity,
        update: [
          set: [
            pool_upstream_assignment_id: ^assignment.id,
            upstream_identity_id: ^identity.id,
            last_hit_at:
              fragment(
                "GREATEST(COALESCE(?, EXCLUDED.last_hit_at), EXCLUDED.last_hit_at)",
                affinity.last_hit_at
              ),
            metadata: ^metadata,
            updated_at: fragment("GREATEST(?, EXCLUDED.updated_at)", affinity.updated_at)
          ]
        ]

    %{
      pool_id: plan_affinity_scope(plan, :pool_id),
      api_key_id: plan_affinity_scope(plan, :api_key_id),
      model_identifier: plan_affinity_scope(plan, :model_identifier),
      affinity_kind: plan.affinity.kind,
      affinity_key_hash: plan.affinity.key_hash,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      status: BridgeAffinity.active_status(),
      last_hit_at: now,
      metadata: metadata,
      created_at: now,
      updated_at: now
    }
    |> then(&struct(BridgeAffinity, &1))
    |> Repo.insert!(
      on_conflict: on_conflict,
      conflict_target: @affinity_conflict_target
    )
  end

  defp mark_affinity_miss!(plan, now) do
    case plan.affinity.row do
      %BridgeAffinity{} = affinity ->
        affinity
        |> Ecto.Changeset.change(%{last_miss_at: now, updated_at: now})
        |> Repo.update!()

      nil ->
        :ok
    end
  end

  defp upsert_demotion!(plan, assignment, identity, reason_code, request_id, now) do
    metadata = %{"source" => "gateway_failure"}
    demoted_until = DateTime.add(now, @demotion_seconds, :second)

    attrs = %{
      reason_code: reason_code,
      upstream_identity_id: identity.id,
      demoted_until: demoted_until,
      last_request_id: request_id,
      metadata: metadata,
      updated_at: now
    }

    on_conflict =
      from demotion in BridgeDemotion,
        update: [
          set: [
            reason_code: ^reason_code,
            upstream_identity_id: ^identity.id,
            demoted_until:
              fragment(
                "GREATEST(COALESCE(?, EXCLUDED.demoted_until), EXCLUDED.demoted_until)",
                demotion.demoted_until
              ),
            last_request_id: ^request_id,
            metadata: ^metadata,
            updated_at: fragment("GREATEST(?, EXCLUDED.updated_at)", demotion.updated_at)
          ],
          inc: [attempt_count: 1]
        ]

    %BridgeDemotion{
      pool_id: plan_affinity_scope(plan, :pool_id),
      api_key_id: plan_affinity_scope(plan, :api_key_id),
      model_identifier: plan_affinity_scope(plan, :model_identifier),
      pool_upstream_assignment_id: assignment.id,
      status: BridgeDemotion.active_status(),
      attempt_count: 1,
      created_at: now
    }
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!(
      on_conflict: on_conflict,
      conflict_target: @demotion_conflict_target
    )
  end

  defp resolve_demotions!(plan, assignment, now) do
    active_status = BridgeDemotion.active_status()
    resolved_status = BridgeDemotion.resolved_status()

    BridgeDemotion
    |> where(
      [demotion],
      demotion.pool_id == ^plan_affinity_scope(plan, :pool_id) and
        demotion.api_key_id == ^plan_affinity_scope(plan, :api_key_id) and
        demotion.model_identifier == ^plan_affinity_scope(plan, :model_identifier) and
        demotion.pool_upstream_assignment_id == ^assignment.id and
        demotion.status == ^active_status
    )
    |> Repo.update_all(set: [status: resolved_status, updated_at: now])
  end

  defp plan_affinity_scope(plan, key), do: Map.fetch!(plan.affinity, key)

  defp latest_success_by_assignment(candidates) do
    assignment_ids = Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)
    Accounting.latest_success_by_assignment_ids(assignment_ids)
  end

  defp rotate_candidates(candidates, _seed) when length(candidates) <= 1, do: candidates

  defp rotate_candidates(candidates, seed) do
    {head, tail} = Enum.split(candidates, :erlang.phash2(seed, length(candidates)))
    tail ++ head
  end

  defp quota_headroom_score(identity, %Model{} = model) do
    identity
    |> QuotaWindows.quota_window_selection_data(quota_scope_opts(model))
    |> Map.get(:routing_windows, [])
    |> Enum.filter(&QuotaWindows.usable_window?/1)
    |> Enum.map(&remaining_percent/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> 0 end)
  end

  defp quota_scope_opts(%Model{} = model) do
    [
      model: model.exposed_model_id,
      requested_model: model.exposed_model_id,
      catalog_model: model.exposed_model_id,
      exposed_model_id: model.exposed_model_id,
      upstream_model: model.upstream_model_id,
      upstream_model_id: model.upstream_model_id
    ]
  end

  defp remaining_percent(%{used_percent: %Decimal{} = used_percent}) do
    Decimal.new(100)
    |> Decimal.sub(used_percent)
    |> Decimal.to_float()
  end

  defp remaining_percent(_window), do: nil

  defp rendezvous_score(seed, assignment_id) do
    :crypto.hash(:sha256, [to_string(seed), ?:, assignment_id])
    |> :binary.decode_unsigned()
  end

  defp sanitized_reason_code("upstream_status"), do: "upstream_status"
  defp sanitized_reason_code("retryable_upstream_status"), do: "retryable_upstream_status"
  defp sanitized_reason_code("upstream_rate_limited"), do: "upstream_rate_limited"
  defp sanitized_reason_code("upstream_unauthorized"), do: "upstream_unauthorized"
  defp sanitized_reason_code("upstream_5xx"), do: "upstream_5xx"
  defp sanitized_reason_code("upstream_network_error"), do: "upstream_network_error"
  defp sanitized_reason_code(code) when is_binary(code), do: String.slice(code, 0, 80)
  defp sanitized_reason_code(code), do: code |> to_string() |> String.slice(0, 80)

  defp default_settings(pool_id) do
    %RoutingSettings{
      pool_id: pool_id,
      routing_strategy: @default_strategy,
      bridge_ring_size: @default_ring_size,
      sticky_websocket_sessions: true,
      sticky_http_sessions: false,
      metadata: %{}
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
