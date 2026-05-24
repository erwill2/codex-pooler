defmodule CodexPooler.Admin.ActivityReadModel do
  @moduledoc """
  Safe recent activity projection for admin dashboards.
  """

  import Ecto.Query

  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Repo

  @spec recent_activity_for_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: [map()]
  def recent_activity_for_pool_ids([], _started_at, _ended_at), do: []

  def recent_activity_for_pool_ids(pool_ids, started_at, ended_at) do
    pool_ids
    |> audit_events_for(started_at, ended_at)
    |> recent_activity(jobs_for(pool_ids, started_at, ended_at))
  end

  @spec activity_source_counts([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: map()
  def activity_source_counts([], _started_at, _ended_at), do: %{audit_events: 0, jobs: 0}

  def activity_source_counts(pool_ids, started_at, ended_at) do
    %{
      audit_events: length(audit_events_for(pool_ids, started_at, ended_at)),
      jobs: length(jobs_for(pool_ids, started_at, ended_at))
    }
  end

  defp audit_events_for(pool_ids, started_at, ended_at) do
    Repo.all(
      from event in AuditEvent,
        where:
          event.pool_id in ^pool_ids and event.occurred_at >= ^started_at and
            event.occurred_at <= ^ended_at,
        order_by: [desc: event.occurred_at, desc: event.id],
        limit: 5,
        select: %{
          type: :audit_event,
          id: event.id,
          occurred_at: event.occurred_at,
          pool_id: event.pool_id,
          action: event.action,
          target_type: event.target_type,
          outcome: event.outcome
        }
    )
  end

  defp jobs_for(pool_ids, started_at, ended_at) do
    Repo.all(
      from job in Oban.Job,
        where:
          fragment("?->>?", job.args, "pool_id") in ^pool_ids and
            job.inserted_at >= ^started_at and job.inserted_at <= ^ended_at,
        order_by: [desc: job.inserted_at, desc: job.id],
        limit: 5,
        select: %{
          type: :job,
          id: job.id,
          occurred_at: job.inserted_at,
          state: job.state,
          worker: job.worker,
          queue: job.queue
        }
    )
  end

  defp recent_activity(audit_activity, job_activity) do
    (audit_activity ++ job_activity)
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
    |> Enum.take(10)
  end
end
