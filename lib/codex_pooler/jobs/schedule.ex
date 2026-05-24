defmodule CodexPooler.Jobs.Schedule do
  @moduledoc false

  @type entry :: %{
          required(:key) => atom(),
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:description) => String.t(),
          required(:icon) => String.t(),
          required(:workers) => [module()],
          required(:cadence) => %{required(:label) => String.t(), optional(:cron) => String.t()},
          optional(:scheduled_worker) => module()
        }

  @spec entries() :: [entry()]
  def entries do
    :codex_pooler
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:entries)
  end

  @spec oban_crontab() :: [{String.t(), module()}]
  def oban_crontab do
    entries()
    |> Enum.flat_map(fn
      %{cadence: %{cron: cron}, scheduled_worker: worker} when is_binary(cron) ->
        [{cron, worker}]

      _entry ->
        []
    end)
  end

  @spec worker_groups() :: [map()]
  def worker_groups do
    Enum.map(entries(), fn entry ->
      %{
        key: entry.key,
        id: entry.id,
        title: entry.title,
        description: entry.description,
        icon: entry.icon,
        workers: Enum.map(entry.workers, &worker_name/1),
        cadence: Map.put_new(entry.cadence, :cron, nil)
      }
    end)
  end

  defp worker_name(worker) when is_atom(worker) do
    worker
    |> Module.split()
    |> Enum.join(".")
  end
end
