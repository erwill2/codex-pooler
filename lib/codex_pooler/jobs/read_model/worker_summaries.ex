defmodule CodexPooler.Jobs.ReadModel.WorkerSummaries do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Jobs.ReadModel.Query
  alias CodexPooler.Repo

  @completed_state "completed"

  def load(worker_groups) do
    now = DateTime.utc_now()
    worker_groups = Query.normalize_worker_groups(worker_groups)
    latest_by_group = latest_worker_jobs_by_group(worker_groups)
    latest_success_by_group = latest_worker_jobs_by_group(worker_groups, state: @completed_state)

    latest_failure_by_group =
      latest_worker_jobs_by_group(worker_groups, states: Query.failure_states())

    pending_by_group = next_pending_worker_jobs_by_group(worker_groups)
    open_by_group = open_worker_jobs_by_group(worker_groups)
    unresolved_failures_by_group = unresolved_failure_worker_jobs_by_group(worker_groups)

    Map.new(worker_groups, fn {group_key, _workers} ->
      summary = %{
        empty_summary()
        | latest: Map.get(latest_by_group, group_key),
          latest_success: Map.get(latest_success_by_group, group_key),
          latest_failure: Map.get(latest_failure_by_group, group_key),
          pending: Map.get(pending_by_group, group_key),
          open: Map.get(open_by_group, group_key, []),
          unresolved_failures: Map.get(unresolved_failures_by_group, group_key, [])
      }

      {group_key, with_attention(summary, now: now)}
    end)
  end

  def empty_summary do
    %{
      latest: nil,
      latest_success: nil,
      latest_failure: nil,
      pending: nil,
      open: [],
      unresolved_failures: []
    }
  end

  def empty_by_group(worker_groups) do
    Map.new(Query.normalize_worker_groups(worker_groups), fn {group_key, _workers} ->
      {group_key, empty_summary()}
    end)
  end

  defp with_attention(summary, opts) do
    now = Query.attention_now(opts)

    %{
      summary
      | latest: Query.with_attention(summary.latest, now: now),
        latest_success: Query.with_attention(summary.latest_success, now: now),
        latest_failure: Query.with_attention(summary.latest_failure, now: now),
        pending: Query.with_attention(summary.pending, now: now),
        open: Query.with_attention(summary.open, now: now),
        unresolved_failures: Query.with_attention(summary.unresolved_failures, now: now)
    }
  end

  defp latest_worker_jobs_by_group(worker_groups, opts \\ []) do
    {group_worker_rows, group_keys_by_index} = Query.group_worker_rows_by_index(worker_groups)

    if group_worker_rows == [] do
      %{}
    else
      group_worker_rows
      |> ranked_latest_worker_jobs_query(opts)
      |> Query.grouped_job_metadata_query()
      |> Repo.all()
      |> Map.new(fn %{group_index: group_index, job: job} ->
        {Map.fetch!(group_keys_by_index, group_index), job}
      end)
    end
  end

  defp ranked_latest_worker_jobs_query(group_worker_rows, opts) do
    group_worker_types = %{group_index: :integer, worker: :string}

    query =
      from job in Oban.Job,
        join: group_worker in values(group_worker_rows, group_worker_types),
        on: job.worker == group_worker.worker

    ranked_query =
      query
      |> Query.maybe_where_states(opts)
      |> Query.exclude_terminal_reauth_reconciliation_failures()
      |> then(fn queryable ->
        from [job, group_worker_row] in queryable,
          windows: [
            group_partition: [
              partition_by: group_worker_row.group_index,
              order_by: [desc: job.inserted_at, desc: job.id]
            ]
          ],
          select: %{
            id: job.id,
            group_index: group_worker_row.group_index,
            row_number: over(row_number(), :group_partition)
          }
      end)

    ranked_query
    |> subquery()
    |> then(fn ranked ->
      from ranked_job in ranked,
        where: ranked_job.row_number == 1,
        select: %{id: ranked_job.id, group_index: ranked_job.group_index}
    end)
  end

  defp next_pending_worker_jobs_by_group(worker_groups) do
    {group_worker_rows, group_keys_by_index} = Query.group_worker_rows_by_index(worker_groups)

    if group_worker_rows == [] do
      %{}
    else
      group_worker_rows
      |> ranked_next_pending_worker_jobs_query()
      |> Query.grouped_job_metadata_query()
      |> Repo.all()
      |> Map.new(fn %{group_index: group_index, job: job} ->
        {Map.fetch!(group_keys_by_index, group_index), job}
      end)
    end
  end

  defp ranked_next_pending_worker_jobs_query(group_worker_rows) do
    group_worker_types = %{group_index: :integer, worker: :string}

    ranked_query =
      from job in Oban.Job,
        join: group_worker in values(group_worker_rows, group_worker_types),
        on: job.worker == group_worker.worker,
        where: job.state in ^Query.open_job_states(),
        windows: [
          group_partition: [
            partition_by: group_worker.group_index,
            order_by: [asc: job.scheduled_at, desc: job.id]
          ]
        ],
        select: %{
          id: job.id,
          group_index: group_worker.group_index,
          row_number: over(row_number(), :group_partition)
        }

    ranked_query
    |> subquery()
    |> then(fn ranked ->
      from ranked_job in ranked,
        where: ranked_job.row_number == 1,
        select: %{id: ranked_job.id, group_index: ranked_job.group_index}
    end)
  end

  defp open_worker_jobs_by_group(worker_groups) do
    {group_worker_rows, group_keys_by_index} = Query.group_worker_rows_by_index(worker_groups)

    if group_worker_rows == [] do
      %{}
    else
      group_worker_rows
      |> grouped_open_worker_jobs_query()
      |> Query.grouped_job_metadata_query(:scheduled)
      |> Repo.all()
      |> Query.grouped_job_lists_by_group(group_keys_by_index)
    end
  end

  defp grouped_open_worker_jobs_query(group_worker_rows) do
    group_worker_types = %{group_index: :integer, worker: :string}

    from job in Oban.Job,
      join: group_worker in values(group_worker_rows, group_worker_types),
      on: job.worker == group_worker.worker,
      where: job.state in ^Query.open_job_states(),
      select: %{id: job.id, group_index: group_worker.group_index}
  end

  defp unresolved_failure_worker_jobs_by_group(worker_groups) do
    {group_worker_rows, group_keys_by_index} = Query.group_worker_rows_by_index(worker_groups)

    if group_worker_rows == [] do
      %{}
    else
      group_worker_rows
      |> grouped_unresolved_failure_worker_jobs_query()
      |> Query.grouped_job_metadata_query(:inserted_desc)
      |> Repo.all()
      |> reject_reauth_required_grouped_reconciliation_failures()
      |> Query.grouped_job_lists_by_group(group_keys_by_index)
    end
  end

  defp grouped_unresolved_failure_worker_jobs_query(group_worker_rows) do
    group_worker_types = %{group_index: :integer, worker: :string}

    query =
      from job in Oban.Job,
        join: group_worker in values(group_worker_rows, group_worker_types),
        on: job.worker == group_worker.worker,
        where: job.state in ^Query.failure_states()

    query
    |> Query.exclude_terminal_reauth_reconciliation_failures()
    |> Query.exclude_resolved_failure_matches()
    |> then(fn queryable ->
      from [job, group_worker_row] in queryable,
        select: %{id: job.id, group_index: group_worker_row.group_index}
    end)
  end

  defp reject_reauth_required_grouped_reconciliation_failures(grouped_jobs) do
    Enum.reject(grouped_jobs, fn %{job: job} ->
      Query.reauth_required_reconciliation_failure?(job)
    end)
  end
end
