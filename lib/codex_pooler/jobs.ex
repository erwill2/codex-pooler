defmodule CodexPooler.Jobs do
  @moduledoc """
  Durable job enqueue and orchestration APIs backed by Oban.
  """

  alias CodexPooler.Events

  alias CodexPooler.Jobs.{
    AccountReconciliationWorker,
    CatalogSyncWorker,
    DailyRollupRebuildWorker,
    DevelopmentControls,
    Options,
    ReadModel,
    RuntimeStateCleanup,
    RuntimeStateCleanupWorker,
    UpstreamEnqueue
  }

  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Reconciliation.AccountReconciliation
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @type pool_ref :: Pool.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type assignment_ref ::
          PoolUpstreamAssignment.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type identity_ref :: UpstreamIdentity.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type missing_ref_error ::
          :pool_id_required
          | :pool_upstream_assignment_id_required
          | :upstream_identity_id_required
  @type job_insert_result ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t() | missing_ref_error()}
  @type batch_insert_result ::
          {:ok,
           %{
             required(:inserted) => [Oban.Job.t()],
             required(:conflicts) => [Oban.Job.t()],
             required(:errors) => [term()]
           }}
  @type job_summary :: ReadModel.job_summary()
  @type worker_job_summary :: ReadModel.worker_job_summary()
  @type orchestration_result :: {:ok, map()} | {:error, term()}

  @spec enqueue_catalog_sync(pool_ref(), keyword()) :: job_insert_result()
  def enqueue_catalog_sync(pool_or_id, opts \\ []) do
    with {:ok, pool_id} <- pool_id(pool_or_id) do
      %{"pool_id" => pool_id, "trigger_kind" => Keyword.get(opts, :trigger_kind, "scheduled")}
      |> CatalogSyncWorker.new(Options.job_options(opts, unique_keys: [:pool_id]))
      |> Oban.insert()
      |> tap_job_status_event(pool_id, "catalog_sync", "scheduled")
    end
  end

  @spec enqueue_catalog_sync_for_active_pools(keyword()) :: batch_insert_result()
  def enqueue_catalog_sync_for_active_pools(opts \\ []) do
    Pools.list_active_pools()
    |> Enum.map(&enqueue_catalog_sync(&1, opts))
    |> split_insert_results()
  end

  @spec enqueue_account_reconciliation(pool_ref(), assignment_ref(), keyword()) ::
          job_insert_result()
  def enqueue_account_reconciliation(pool_or_id, assignment_or_id, opts \\ []) do
    UpstreamEnqueue.enqueue_account_reconciliation(pool_or_id, assignment_or_id, opts)
  end

  @spec enqueue_assignment_priming(pool_ref(), assignment_ref(), keyword()) ::
          job_insert_result() | {:error, term()}
  def enqueue_assignment_priming(pool_or_id, assignment_or_id, opts \\ []) do
    UpstreamEnqueue.enqueue_assignment_priming(pool_or_id, assignment_or_id, opts)
  end

  @spec enqueue_runtime_state_cleanup(keyword()) :: job_insert_result()
  def enqueue_runtime_state_cleanup(opts \\ []) do
    args =
      case Keyword.get(opts, :now) do
        %DateTime{} = now -> %{"now" => DateTime.to_iso8601(DateTime.truncate(now, :microsecond))}
        _value -> %{}
      end

    args
    |> RuntimeStateCleanupWorker.new(Keyword.take(opts, [:scheduled_at, :schedule_in, :unique]))
    |> Oban.insert()
  end

  @spec list_system_jobs(keyword()) :: [job_summary()]
  def list_system_jobs(opts \\ []) do
    ReadModel.list_system_jobs(opts)
  end

  @spec list_latest_jobs(ReadModel.scope_ref(), keyword()) :: [job_summary()]
  def list_latest_jobs(scope, opts \\ []), do: ReadModel.list_latest_jobs(scope, opts)

  @spec worker_job_summary(ReadModel.scope_ref(), [String.t()]) :: worker_job_summary()
  def worker_job_summary(scope, workers), do: ReadModel.worker_job_summary(scope, workers)

  @spec cleanup_runtime_state(DateTime.t()) :: orchestration_result()
  def cleanup_runtime_state(now \\ DateTime.utc_now()) do
    RuntimeStateCleanup.run(now)
  end

  @spec enqueue_token_refresh(identity_ref(), keyword()) :: job_insert_result()
  def enqueue_token_refresh(identity_or_id, opts \\ []) do
    UpstreamEnqueue.enqueue_token_refresh(identity_or_id, opts)
  end

  @spec list_recent_token_refresh_jobs(identity_ref(), keyword()) :: [job_summary()]
  defdelegate list_recent_token_refresh_jobs(identity_or_id, opts \\ []), to: ReadModel

  @spec enqueue_account_reconciliations(pool_ref(), keyword()) ::
          batch_insert_result() | {:error, :pool_id_required}
  def enqueue_account_reconciliations(pool_or_id, opts \\ []) do
    with {:ok, pool_id} <- pool_id(pool_or_id) do
      pool_id
      |> PoolAssignments.list_active_pool_assignments()
      |> Enum.map(&enqueue_account_reconciliation(pool_id, &1, opts))
      |> split_insert_results()
    end
  end

  @spec enqueue_account_reconciliation_for_active_pools(keyword()) :: batch_insert_result()
  def enqueue_account_reconciliation_for_active_pools(opts \\ []) do
    unless DevelopmentControls.account_reconciliation_paused?() do
      AccountReconciliation.discard_stale_jobs(
        DateTime.utc_now(),
        worker_name(AccountReconciliationWorker)
      )
    end

    active_pools_for_account_reconciliation()
    |> Enum.map(&enqueue_account_reconciliations(&1, opts))
    |> split_insert_results()
  end

  @spec list_recent_account_reconciliation_jobs(pool_ref(), keyword()) :: [job_summary()]
  defdelegate list_recent_account_reconciliation_jobs(pool_or_id, opts \\ []), to: ReadModel

  @spec enqueue_daily_rollup_rebuild(Date.t(), keyword()) :: job_insert_result()
  def enqueue_daily_rollup_rebuild(date \\ yesterday_utc(), opts \\ []) do
    rollup_date = Date.to_iso8601(date)

    %{"rollup_date" => rollup_date}
    |> DailyRollupRebuildWorker.new(Options.job_options(opts, unique_keys: [:rollup_date]))
    |> Oban.insert()
  end

  defp tap_job_status_event({:ok, job} = result, pool_id, worker, status) do
    Events.broadcast_job_status(pool_id, "job_status_updated", %{
      id: Integer.to_string(job.id),
      worker: worker,
      status: status
    })

    result
  end

  defp tap_job_status_event(result, _pool_id, _worker, _status), do: result

  defp split_insert_results(results) do
    Enum.reduce(results, {:ok, %{inserted: [], conflicts: [], errors: []}}, fn
      {:ok, %{inserted: inserted, conflicts: conflicts, errors: errors}}, {:ok, acc} ->
        {:ok,
         %{
           inserted: inserted ++ acc.inserted,
           conflicts: conflicts ++ acc.conflicts,
           errors: errors ++ acc.errors
         }}

      {:ok, %{conflict?: true} = job}, {:ok, acc} ->
        {:ok, %{acc | conflicts: [job | acc.conflicts]}}

      {:ok, job}, {:ok, acc} ->
        {:ok, %{acc | inserted: [job | acc.inserted]}}

      {:error, reason}, {:ok, acc} ->
        {:ok, %{acc | errors: [reason | acc.errors]}}
    end)
  end

  defp active_pools_for_account_reconciliation do
    if DevelopmentControls.account_reconciliation_paused?() do
      []
    else
      Pools.list_active_pools()
    end
  end

  defp yesterday_utc, do: Date.utc_today() |> Date.add(-1)
  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  defp pool_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp pool_id(id) when is_binary(id), do: {:ok, id}
  defp pool_id(_pool_or_id), do: {:error, :pool_id_required}
end
