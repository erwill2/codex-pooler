defmodule CodexPooler.Jobs.HealthPolicy do
  @moduledoc """
  Classifies Oban job rows into admin attention states.
  """

  alias CodexPooler.Jobs.Schedule

  @backlog_pressure_after_seconds 5 * 60

  @type attention_state ::
          :active_failure
          | :retry_pressure
          | :backlog_pressure
          | :stuck_executing
          | :executing
          | :available
          | :scheduled
          | :cancelled
          | :healthy_context
          | :suspended
          | :unknown_state

  @type job_projection :: %{
          required(:state) => String.t(),
          required(:worker) => String.t(),
          optional(:inserted_at) => DateTime.t() | nil,
          optional(:scheduled_at) => DateTime.t() | nil,
          optional(:attempted_at) => DateTime.t() | nil
        }

  @spec classify(job_projection(), keyword()) :: attention_state()
  def classify(job, opts \\ []) when is_map(job) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    classify_state(job_state(job), job, now)
  end

  defp classify_state("discarded", _job, _now), do: :active_failure
  defp classify_state("retryable", _job, _now), do: :retry_pressure
  defp classify_state("available", job, now), do: classify_due_state(job, now, :available)
  defp classify_state("scheduled", job, now), do: classify_due_state(job, now, :scheduled)
  defp classify_state("executing", job, now), do: classify_executing(job, now)
  defp classify_state("cancelled", _job, _now), do: :cancelled
  defp classify_state("completed", _job, _now), do: :healthy_context
  defp classify_state("suspended", _job, _now), do: :suspended
  defp classify_state(_state, _job, _now), do: :unknown_state

  @spec put_attention(map(), keyword()) :: map()
  def put_attention(job, opts \\ []) when is_map(job) do
    Map.put(job, :attention_state, classify(job, opts))
  end

  @spec known_worker_timeout_ms(String.t()) :: non_neg_integer() | nil
  def known_worker_timeout_ms(worker_name) when is_binary(worker_name) do
    worker_timeouts_by_name()
    |> Map.get(worker_name)
  end

  def known_worker_timeout_ms(_worker_name), do: nil

  defp classify_due_state(job, now, default_state) do
    if overdue?(job, now), do: :backlog_pressure, else: default_state
  end

  defp classify_executing(job, now) do
    with timeout_ms when is_integer(timeout_ms) <- known_worker_timeout_ms(job_worker(job)),
         %DateTime{} = started_at <- execution_started_at(job),
         true <- DateTime.diff(now, started_at, :millisecond) > timeout_ms do
      :stuck_executing
    else
      _not_stuck_or_unknown -> :executing
    end
  end

  defp overdue?(job, now) do
    case due_at(job) do
      %DateTime{} = due_at ->
        threshold = DateTime.add(now, -@backlog_pressure_after_seconds, :second)
        DateTime.compare(due_at, threshold) in [:lt, :eq]

      _missing_due_at ->
        false
    end
  end

  defp due_at(job), do: job_timestamp(job, :scheduled_at) || job_timestamp(job, :inserted_at)

  defp execution_started_at(job),
    do: job_timestamp(job, :attempted_at) || job_timestamp(job, :inserted_at)

  defp worker_timeouts_by_name do
    Schedule.entries()
    |> Enum.flat_map(& &1.workers)
    |> Enum.uniq()
    |> Map.new(fn worker -> {worker_name(worker), timeout_ms(worker)} end)
  end

  defp timeout_ms(worker) when is_atom(worker) do
    with {:module, ^worker} <- Code.ensure_loaded(worker),
         true <- function_exported?(worker, :timeout, 1),
         timeout when is_integer(timeout) and timeout >= 0 <- worker.timeout(%Oban.Job{}) do
      timeout
    else
      _unavailable -> nil
    end
  end

  defp job_state(job), do: job_field(job, :state)
  defp job_worker(job), do: job_field(job, :worker)

  defp job_timestamp(job, key) do
    case job_field(job, key) do
      %DateTime{} = timestamp -> timestamp
      _value -> nil
    end
  end

  defp job_field(job, key) when is_atom(key) do
    Map.get(job, key) || Map.get(job, Atom.to_string(key))
  end

  defp worker_name(worker) when is_atom(worker) do
    worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  end
end
