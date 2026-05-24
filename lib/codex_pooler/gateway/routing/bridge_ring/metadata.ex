defmodule CodexPooler.Gateway.Routing.BridgeRing.Metadata do
  @moduledoc false

  alias CodexPooler.Gateway.Routing.BridgeRing
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @default_ring_size 3

  @spec attempt_metadata(
          BridgeRing.route_plan(),
          PoolUpstreamAssignment.t(),
          UpstreamIdentity.t(),
          non_neg_integer()
        ) :: map()
  def attempt_metadata(plan, assignment, identity, rank) do
    %{
      "routing" =>
        base_metadata(plan)
        |> Map.merge(%{
          "bridge_candidate_id" => assignment.id,
          "bridge_candidate_rank" => rank + 1,
          "upstream_identity_id" => identity.id
        })
    }
  end

  @spec selected_metadata(BridgeRing.route_plan(), PoolUpstreamAssignment.t(), non_neg_integer()) ::
          map()
  def selected_metadata(_plan, assignment, rank) do
    %{
      "routing" => %{
        "selected_bridge_candidate_id" => assignment.id,
        "selected_bridge_candidate_rank" => rank + 1
      }
    }
  end

  @spec demotion_metadata(term()) :: map()
  def demotion_metadata(reason_code) do
    %{"routing" => %{"demotion_reason" => sanitized_reason_code(reason_code)}}
  end

  @spec request_metadata(
          RoutingSettings.t(),
          BridgeRing.affinity_context(),
          BridgeRing.demotion_map(),
          BridgeRing.candidate() | nil
        ) :: map()
  def request_metadata(settings, affinity, demotions, selected) do
    base_metadata(%{
      strategy: settings.routing_strategy,
      bridge_ring_size: max(settings.bridge_ring_size || @default_ring_size, 1),
      affinity: affinity,
      demotions: demotions,
      selected_assignment_id: selected && elem(selected, 0).id
    })
  end

  defp base_metadata(plan) do
    affinity = Map.get(plan, :affinity, %{})
    demotions = Map.get(plan, :demotions, %{})

    %{
      "strategy" => plan.strategy,
      "bridge_ring_size" => plan.bridge_ring_size,
      "selected_bridge_candidate_id" => Map.get(plan, :selected_assignment_id),
      "affinity_enabled" => Map.get(affinity, :enabled?, false),
      "affinity_kind" => Map.get(affinity, :kind),
      "affinity_status" => Map.get(affinity, :status, "disabled"),
      "affinity_hit" => Map.get(affinity, :status) == "hit",
      "fallback_reason" => fallback_reason(affinity),
      "demotion_reason" => first_demotion_reason(demotions)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp fallback_reason(%{enabled?: true, status: "miss", row: nil}), do: "affinity_not_found"
  defp fallback_reason(%{enabled?: true, status: "hit"}), do: nil
  defp fallback_reason(%{enabled?: false}), do: "affinity_disabled"
  defp fallback_reason(_affinity), do: nil

  defp first_demotion_reason(demotions) when map_size(demotions) == 0, do: nil

  defp first_demotion_reason(demotions) do
    demotions
    |> Map.values()
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> List.first()
    |> then(&(&1 && &1.reason_code))
  end

  defp sanitized_reason_code("upstream_status"), do: "upstream_status"
  defp sanitized_reason_code("retryable_upstream_status"), do: "retryable_upstream_status"
  defp sanitized_reason_code("upstream_rate_limited"), do: "upstream_rate_limited"
  defp sanitized_reason_code("upstream_unauthorized"), do: "upstream_unauthorized"
  defp sanitized_reason_code("upstream_5xx"), do: "upstream_5xx"
  defp sanitized_reason_code("upstream_network_error"), do: "upstream_network_error"
  defp sanitized_reason_code(code) when is_binary(code), do: String.slice(code, 0, 80)
  defp sanitized_reason_code(code), do: code |> to_string() |> String.slice(0, 80)
end
