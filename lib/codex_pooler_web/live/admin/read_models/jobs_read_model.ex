defmodule CodexPoolerWeb.Admin.JobsReadModel do
  @moduledoc false

  alias CodexPooler.Jobs.ReadModel
  alias CodexPooler.Jobs.Schedule

  @type worker_jobs_by_group :: %{optional(atom()) => ReadModel.worker_job_summary()}
  @type page_state :: %{
          required(:recent_jobs) => [ReadModel.job_summary()],
          required(:worker_jobs_by_group) => worker_jobs_by_group()
        }

  @spec load(ReadModel.scope_ref(), keyword()) :: page_state()
  def load(scope, opts \\ []) do
    %{
      recent_jobs: ReadModel.list_latest_jobs(scope, opts),
      worker_jobs_by_group: worker_jobs_by_group(scope)
    }
  end

  @spec worker_jobs_by_group(ReadModel.scope_ref()) :: worker_jobs_by_group()
  def worker_jobs_by_group(scope) do
    Map.new(Schedule.worker_groups(), fn group ->
      {group.key, ReadModel.worker_job_summary(scope, group.workers)}
    end)
  end
end
