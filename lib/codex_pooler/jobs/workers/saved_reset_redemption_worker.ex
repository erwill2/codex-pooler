defmodule CodexPooler.Jobs.SavedResetRedemptionWorker do
  @moduledoc """
  Redeems one saved Codex reset credit for an upstream assignment.
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 1,
    tags: ["saved_reset_redemption"],
    unique: [
      fields: [:args, :queue, :worker],
      keys: [:pool_upstream_assignment_id],
      states: :incomplete,
      period: {10, :minutes}
    ]

  alias CodexPooler.Upstreams.SavedResetRedemption

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.seconds(45)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pool_upstream_assignment_id" => assignment_id} = args}) do
    trigger_kind = Map.get(args, "trigger_kind", "admin_manual")

    case SavedResetRedemption.redeem(assignment_id, trigger_kind: trigger_kind) do
      {:ok, %{status: :succeeded}} ->
        :ok

      {:ok, %{status: :noop}} ->
        :discard

      {:ok, %{status: :failed, reason: reason}} ->
        {:error, reason}

      {:ok, %{status: :failed}} ->
        {:error, :saved_reset_redemption_failed}

      {:error, :redemption_in_progress} ->
        {:snooze, 5}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
