defmodule CodexPooler.Jobs.AccountReconciliationEnqueueWorker do
  @moduledoc """
  Periodically enqueues account reconciliation jobs for active Pool assignments.
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 1,
    tags: ["account_reconciliation_enqueue"],
    unique: [
      fields: [:worker, :queue],
      states: :incomplete,
      period: {5, :minutes}
    ]

  alias CodexPooler.Jobs

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Jobs.enqueue_account_reconciliation_for_active_pools(trigger_kind: "scheduled") do
      {:ok, %{errors: []}} -> :ok
      {:ok, %{errors: errors}} -> {:error, {:enqueue_failed, errors}}
    end
  end
end
