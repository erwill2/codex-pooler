defmodule CodexPooler.JobsQueryBudgetDatasets do
  @moduledoc false

  import Ecto.Query
  import ExUnit.Assertions
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Jobs.{
    AccountReconciliationWorker,
    AlertEvaluationWorker,
    CatalogSyncWorker,
    DailyRollupRebuildWorker,
    PricingImportWorker,
    RuntimeStateCleanupWorker,
    Schedule,
    TokenRefreshWorker
  }

  alias CodexPooler.Repo

  @job_update_keys [
    :worker,
    :queue,
    :state,
    :errors,
    :attempt,
    :max_attempts,
    :inserted_at,
    :scheduled_at,
    :attempted_at,
    :completed_at,
    :discarded_at,
    :cancelled_at
  ]

  @worker_by_group %{
    catalog_sync: CatalogSyncWorker,
    pricing_import: PricingImportWorker,
    account_reconciliation: AccountReconciliationWorker,
    alert_evaluation: AlertEvaluationWorker,
    token_refresh: TokenRefreshWorker,
    daily_rollup_rebuild: DailyRollupRebuildWorker,
    runtime_cleanup: RuntimeStateCleanupWorker
  }

  def clear_jobs! do
    Repo.delete_all(Oban.Job)
    :ok
  end

  def worker_group_keys do
    Schedule.worker_groups() |> Enum.map(& &1.key)
  end

  def worker_card_selector(worker_group) do
    "#job-worker-card-#{String.replace(Atom.to_string(worker_group), "_", "-")}"
  end

  def worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  def insert_job!(index, attrs) do
    inserted_at = Keyword.fetch!(attrs, :inserted_at)
    args = Keyword.get(attrs, :args, %{}) |> Map.put_new("index", index)
    meta = Keyword.get(attrs, :meta, %{"source" => "jobs-query-budget-test"})

    assert {:ok, job} =
             args
             |> RuntimeStateCleanupWorker.new(meta: meta, unique: false)
             |> Oban.insert()

    updates =
      attrs
      |> Keyword.take(@job_update_keys)
      |> Keyword.put_new(:state, "available")
      |> Keyword.put_new(:attempt, 0)
      |> Keyword.put_new(:max_attempts, 20)
      |> maybe_put_worker_name()
      |> Keyword.put(:inserted_at, inserted_at)

    {1, _rows} =
      from(oban_job in Oban.Job, where: oban_job.id == ^job.id)
      |> Repo.update_all(set: updates)

    Repo.get!(Oban.Job, job.id)
  end

  def update_job!(job, attrs) do
    updates =
      attrs
      |> Keyword.take(@job_update_keys)
      |> maybe_put_worker_name()

    {1, _rows} =
      from(oban_job in Oban.Job, where: oban_job.id == ^job.id)
      |> Repo.update_all(set: updates)

    Repo.get!(Oban.Job, job.id)
  end

  def delete_job!(job) do
    {1, _rows} =
      from(oban_job in Oban.Job, where: oban_job.id == ^job.id)
      |> Repo.delete_all()

    :ok
  end

  def empty_dataset! do
    %{name: "empty", jobs: [], worker_group_keys: worker_group_keys()}
  end

  def small_realistic_dataset! do
    clear_jobs!()

    pool = pool_fixture(%{name: "Small Ops Pool", slug: unique_slug("small-ops-pool")})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "small-ops@example.com",
        assignment_label: "small-ops@example.com"
      })

    jobs = [
      insert_job!(1,
        worker: CatalogSyncWorker,
        state: "completed",
        inserted_at: ~U[2026-06-04 10:00:00Z],
        completed_at: ~U[2026-06-04 10:01:00Z],
        args: %{"pool_id" => pool.id}
      ),
      insert_job!(2,
        worker: TokenRefreshWorker,
        state: "retryable",
        attempt: 2,
        max_attempts: 5,
        inserted_at: ~U[2026-06-04 10:02:00Z],
        attempted_at: ~U[2026-06-04 10:03:00Z],
        args: %{"upstream_identity_id" => identity.id}
      ),
      insert_job!(3,
        worker: RuntimeStateCleanupWorker,
        state: "executing",
        inserted_at: ~U[2026-06-04 10:04:00Z],
        attempted_at: ~U[2026-06-04 10:05:00Z]
      ),
      insert_job!(4,
        worker: AccountReconciliationWorker,
        state: "available",
        inserted_at: ~U[2026-06-04 10:06:00Z],
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => assignment.id,
          "trigger_kind" => "scheduled"
        }
      ),
      insert_job!(5,
        worker: DailyRollupRebuildWorker,
        state: "scheduled",
        inserted_at: ~U[2026-06-04 10:07:00Z],
        scheduled_at: ~U[2026-06-04 10:17:00Z]
      )
    ]

    %{
      name: "small_realistic",
      jobs: jobs,
      pool: pool,
      identity: identity,
      assignment: assignment,
      worker_group_keys: worker_group_keys()
    }
  end

  def failed_sanitized_dataset! do
    clear_jobs!()

    pool = pool_fixture(%{name: "Failure Pool", slug: unique_slug("failure-pool")})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "failed-ops@example.com",
        assignment_label: "failed-ops@example.com"
      })

    redaction_values = %{
      token: "secret-token-failed-dataset",
      prompt: "raw-prompt-failed-dataset",
      cookie: "cookie-failed-dataset",
      error: "stacktrace-failed-dataset"
    }

    jobs = [
      insert_job!(1,
        worker: TokenRefreshWorker,
        state: "discarded",
        attempt: 3,
        max_attempts: 8,
        inserted_at: ~U[2026-06-04 11:00:00Z],
        discarded_at: ~U[2026-06-04 11:01:00Z],
        args: %{
          "upstream_identity_id" => identity.id,
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => assignment.id,
          "token" => redaction_values.token,
          "prompt" => redaction_values.prompt
        },
        meta: %{"cookie" => redaction_values.cookie},
        errors: [%{"attempt" => 3, "error" => redaction_values.error}]
      ),
      insert_job!(2,
        worker: AccountReconciliationWorker,
        state: "discarded",
        inserted_at: ~U[2026-06-04 11:02:00Z],
        discarded_at: ~U[2026-06-04 11:03:00Z],
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => assignment.id,
          "trigger_kind" => "scheduled"
        },
        errors: [%{"attempt" => 1, "error" => "account reconciliation failed"}]
      )
    ]

    %{
      name: "failed_sanitized",
      jobs: jobs,
      pool: pool,
      identity: identity,
      assignment: assignment,
      redaction_values: redaction_values,
      worker_group_keys: worker_group_keys()
    }
  end

  def heavy_dataset! do
    clear_jobs!()

    active_pool = pool_fixture(%{name: "Heavy Active Pool", slug: unique_slug("heavy-active")})
    failed_pool = pool_fixture(%{name: "Heavy Failed Pool", slug: unique_slug("heavy-failed")})

    %{assignment: active_assignment} =
      upstream_assignment_fixture(active_pool, %{
        account_label: "heavy-active@example.com",
        assignment_label: "heavy-active@example.com"
      })

    %{identity: failed_identity, assignment: failed_assignment} =
      upstream_assignment_fixture(failed_pool, %{
        account_label: "heavy-failed@example.com",
        assignment_label: "heavy-failed@example.com"
      })

    base_jobs = [
      insert_job!(1,
        worker: CatalogSyncWorker,
        state: "executing",
        inserted_at: ~U[2026-06-04 12:00:00Z],
        attempted_at: ~U[2026-06-04 12:01:00Z],
        args: %{"pool_id" => active_pool.id}
      ),
      insert_job!(2,
        worker: PricingImportWorker,
        state: "completed",
        inserted_at: ~U[2026-06-04 12:02:00Z],
        completed_at: ~U[2026-06-04 12:03:00Z]
      ),
      insert_job!(3,
        worker: AccountReconciliationWorker,
        state: "retryable",
        attempt: 1,
        max_attempts: 5,
        inserted_at: ~U[2026-06-04 12:04:00Z],
        attempted_at: ~U[2026-06-04 12:05:00Z],
        args: %{
          "pool_id" => active_pool.id,
          "pool_upstream_assignment_id" => active_assignment.id,
          "trigger_kind" => "scheduled"
        }
      ),
      insert_job!(4,
        worker: AlertEvaluationWorker,
        state: "available",
        inserted_at: ~U[2026-06-04 12:06:00Z]
      ),
      insert_job!(5,
        worker: TokenRefreshWorker,
        state: "discarded",
        attempt: 2,
        max_attempts: 8,
        inserted_at: ~U[2026-06-04 12:07:00Z],
        discarded_at: ~U[2026-06-04 12:08:00Z],
        args: %{
          "upstream_identity_id" => failed_identity.id,
          "pool_id" => failed_pool.id,
          "pool_upstream_assignment_id" => failed_assignment.id
        },
        errors: [%{"attempt" => 2, "error" => "refresh failed"}]
      ),
      insert_job!(6,
        worker: DailyRollupRebuildWorker,
        state: "scheduled",
        inserted_at: ~U[2026-06-04 12:09:00Z],
        scheduled_at: ~U[2026-06-04 12:19:00Z]
      ),
      insert_job!(7,
        worker: RuntimeStateCleanupWorker,
        state: "completed",
        inserted_at: ~U[2026-06-04 12:10:00Z],
        completed_at: ~U[2026-06-04 12:11:00Z]
      )
    ]

    overflow_jobs =
      for index <- 8..32 do
        insert_job!(index,
          worker: AccountReconciliationWorker,
          state: if(rem(index, 2) == 0, do: "available", else: "completed"),
          inserted_at: DateTime.add(~U[2026-06-04 12:20:00Z], index, :second),
          completed_at:
            if(rem(index, 2) == 0,
              do: nil,
              else: DateTime.add(~U[2026-06-04 12:21:00Z], index, :second)
            ),
          args: %{
            "pool_id" => active_pool.id,
            "pool_upstream_assignment_id" => active_assignment.id,
            "trigger_kind" => "scheduled"
          }
        )
      end

    %{
      name: "heavy",
      jobs: base_jobs ++ overflow_jobs,
      pools: [active_pool, failed_pool],
      assignments: [active_assignment, failed_assignment],
      worker_group_keys: worker_group_keys(),
      worker_modules_by_group: @worker_by_group
    }
  end

  def dataset_summary(%{name: name, jobs: jobs, worker_group_keys: group_keys} = dataset) do
    %{
      name: name,
      job_count: length(jobs),
      worker_group_count: length(group_keys),
      present_worker_groups: present_worker_groups(jobs),
      has_failed_jobs?: Enum.any?(jobs, &(&1.state == "discarded")),
      has_scheduled_jobs?: Enum.any?(jobs, &(&1.state == "scheduled")),
      has_completed_jobs?: Enum.any?(jobs, &(&1.state == "completed")),
      has_targeted_jobs?: targeted_jobs?(dataset)
    }
  end

  defp maybe_put_worker_name(updates) do
    if Keyword.has_key?(updates, :worker) do
      Keyword.update!(updates, :worker, &worker_name/1)
    else
      updates
    end
  end

  defp present_worker_groups(jobs) do
    jobs
    |> Enum.map(&worker_group_for_job/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp worker_group_for_job(job) do
    job_worker = job.worker

    Enum.find_value(@worker_by_group, fn {group_key, worker_module} ->
      if worker_name(worker_module) == job_worker, do: group_key
    end)
  end

  defp targeted_jobs?(dataset) do
    Map.has_key?(dataset, :assignment) or Map.has_key?(dataset, :assignments)
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
