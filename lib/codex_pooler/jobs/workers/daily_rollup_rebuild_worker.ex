defmodule CodexPooler.Jobs.DailyRollupRebuildWorker do
  @moduledoc """
  Rebuilds accounting rollups for a single UTC date.
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 3,
    tags: ["daily_rollup_rebuild"],
    unique: [
      fields: [:args, :queue, :worker],
      keys: [:rollup_date],
      states: [:scheduled, :available, :executing, :retryable],
      period: {7, :days}
    ]

  alias CodexPooler.Accounting

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"rollup_date" => rollup_date}}) do
    case rebuild_daily_rollup(rollup_date) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rebuild_daily_rollup(date_text) when is_binary(date_text) do
    with {:ok, date} <- Date.from_iso8601(date_text) do
      Accounting.rebuild_daily_rollups_for_date(date)
    end
  end

  defp rebuild_daily_rollup(_date_text), do: {:error, :invalid_rollup_date}
end
