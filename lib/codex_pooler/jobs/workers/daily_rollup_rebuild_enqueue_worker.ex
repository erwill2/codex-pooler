defmodule CodexPooler.Jobs.DailyRollupRebuildEnqueueWorker do
  @moduledoc """
  Periodically enqueues the previous UTC day's accounting rollup rebuild.
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 3,
    tags: ["daily_rollup_rebuild_enqueue"],
    unique: [
      fields: [:worker, :queue],
      states: [:scheduled, :available, :executing, :retryable],
      period: {1, :day}
    ]

  alias CodexPooler.Jobs

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Jobs.enqueue_daily_rollup_rebuild() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
