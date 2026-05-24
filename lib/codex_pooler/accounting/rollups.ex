defmodule CodexPooler.Accounting.Rollups do
  @moduledoc """
  Daily rollup mutation, rebuild, and read helpers for accounting usage data.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.{DailyRollup, LedgerEntry, Request}
  alias CodexPooler.Repo

  @entry_settlement "settlement"
  @amount_recorded "recorded"
  @usage_known "usage_known"

  @spec accumulate!(Request.t(), LedgerEntry.t()) :: :ok
  def accumulate!(%Request{} = request, %LedgerEntry{} = settlement) do
    delta = rollup_delta(request, settlement)
    date = DateTime.to_date(settlement.occurred_at || now())

    upsert_rollup!(%{dimension_kind: "pool", pool_id: request.pool_id}, date, delta)

    upsert_rollup!(
      %{dimension_kind: "api_key", pool_id: request.pool_id, api_key_id: request.api_key_id},
      date,
      delta
    )

    if settlement.pool_upstream_assignment_id do
      upsert_rollup!(
        %{
          dimension_kind: "pool_upstream_assignment",
          pool_id: request.pool_id,
          pool_upstream_assignment_id: settlement.pool_upstream_assignment_id
        },
        date,
        delta
      )
    end

    if settlement.upstream_identity_id do
      upsert_rollup!(
        %{
          dimension_kind: "upstream_identity",
          pool_id: request.pool_id,
          upstream_identity_id: settlement.upstream_identity_id
        },
        date,
        delta
      )
    end

    if request.model_id do
      upsert_rollup!(
        %{dimension_kind: "model", pool_id: request.pool_id, model_id: request.model_id},
        date,
        delta
      )
    end

    :ok
  end

  @spec list(term(), keyword()) :: [term()]
  def list(pool_or_id, opts \\ []) do
    date = Keyword.get(opts, :date, Date.utc_today())
    dimension_kind = Keyword.get(opts, :dimension_kind)
    pool_id = id_for(pool_or_id)

    DailyRollup
    |> where([r], r.pool_id == ^pool_id and r.rollup_date == ^date)
    |> maybe_where_dimension(dimension_kind)
    |> order_by([r],
      asc: r.dimension_kind,
      asc: r.api_key_id,
      asc: r.pool_upstream_assignment_id,
      asc: r.upstream_identity_id,
      asc: r.model_id
    )
    |> Repo.all()
  end

  @spec rebuild_for_date(Date.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rebuild_for_date(%Date{} = date) do
    start_at = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end_at = DateTime.add(start_at, 1, :day)

    Repo.transaction(fn ->
      Repo.delete_all(from r in DailyRollup, where: r.rollup_date == ^date)

      settlements =
        Repo.all(
          from entry in LedgerEntry,
            join: request in Request,
            on: request.id == entry.request_id,
            where:
              entry.entry_kind == @entry_settlement and entry.amount_status == @amount_recorded and
                entry.occurred_at >= ^start_at and entry.occurred_at < ^end_at,
            select: {request, entry},
            order_by: [asc: entry.occurred_at, asc: entry.created_at]
        )

      Enum.each(settlements, fn {request, settlement} -> accumulate!(request, settlement) end)

      length(settlements)
    end)
    |> unwrap_transaction()
  end

  def rebuild_for_date(_date), do: {:error, :invalid_rollup_date}

  defp upsert_rollup!(identity, date, delta) do
    now = now()
    existing = Repo.get_by(DailyRollup, rollup_lookup(identity, date))

    attrs = Map.merge(identity, Map.merge(delta, %{rollup_date: date, updated_at: now}))

    case existing do
      %DailyRollup{} = rollup ->
        rollup
        |> Ecto.Changeset.change(%{
          request_count: rollup.request_count + delta.request_count,
          success_count: rollup.success_count + delta.success_count,
          failure_count: rollup.failure_count + delta.failure_count,
          retry_count: rollup.retry_count + delta.retry_count,
          input_tokens: rollup.input_tokens + delta.input_tokens,
          cached_input_tokens: rollup.cached_input_tokens + delta.cached_input_tokens,
          output_tokens: rollup.output_tokens + delta.output_tokens,
          reasoning_tokens: rollup.reasoning_tokens + delta.reasoning_tokens,
          total_tokens: rollup.total_tokens + delta.total_tokens,
          estimated_cost_micros:
            Decimal.add(rollup.estimated_cost_micros, delta.estimated_cost_micros),
          settled_cost_micros: Decimal.add(rollup.settled_cost_micros, delta.settled_cost_micros),
          updated_at: now
        })
        |> Repo.update!()

      nil ->
        attrs
        |> Map.put(:created_at, now)
        |> then(&struct(DailyRollup, &1))
        |> Repo.insert!()
    end
  end

  defp rollup_lookup(
         %{dimension_kind: "upstream_identity", upstream_identity_id: upstream_identity_id},
         date
       ) do
    %{
      dimension_kind: "upstream_identity",
      upstream_identity_id: upstream_identity_id,
      rollup_date: date
    }
  end

  defp rollup_lookup(identity, date), do: Map.merge(identity, %{rollup_date: date})

  defp rollup_delta(request, settlement) do
    %{
      request_count: 1,
      success_count: success_count(request),
      failure_count: failure_count(request),
      retry_count: request.retry_count || 0,
      input_tokens: settlement.input_tokens || 0,
      cached_input_tokens: settlement.cached_input_tokens || 0,
      output_tokens: settlement.output_tokens || 0,
      reasoning_tokens: settlement.reasoning_tokens || 0,
      total_tokens: settlement.total_tokens || 0,
      estimated_cost_micros: settlement.estimated_cost_micros || Decimal.new(0),
      settled_cost_micros: settled_rollup_cost(settlement)
    }
  end

  defp success_count(%Request{status: "succeeded"}), do: 1
  defp success_count(%Request{}), do: 0

  defp failure_count(%Request{status: "succeeded"}), do: 0
  defp failure_count(%Request{}), do: 1

  defp settled_rollup_cost(%LedgerEntry{usage_status: @usage_known, settled_cost_micros: cost}),
    do: cost || Decimal.new(0)

  defp settled_rollup_cost(%LedgerEntry{}), do: Decimal.new(0)

  defp maybe_where_dimension(query, nil), do: query

  defp maybe_where_dimension(query, dimension_kind),
    do: from(r in query, where: r.dimension_kind == ^dimension_kind)

  defp id_for(%{id: id}), do: id
  defp id_for(id) when is_binary(id), do: id
  defp id_for(_), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, value}), do: {:error, value}
end
