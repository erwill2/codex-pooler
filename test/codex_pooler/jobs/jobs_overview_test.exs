defmodule CodexPooler.Jobs.JobsOverviewTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Jobs.ReadModel

  alias CodexPooler.Jobs.{
    CatalogSyncWorker,
    RuntimeStateCleanupWorker,
    TokenRefreshWorker
  }

  alias CodexPooler.Repo

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  describe "jobs overview" do
    test "counts actionable attention buckets across the full system scope with safe newest examples" do
      now = ~U[2026-06-02 10:30:00Z]

      older_failure =
        insert_overview_job(1,
          state: "discarded",
          inserted_at: ~U[2026-06-02 10:00:00Z],
          discarded_at: ~U[2026-06-02 10:01:00Z],
          args: %{"upstream_identity_id" => "00000000-0000-0000-0000-000000000101"}
        )

      newest_failure =
        insert_overview_job(2,
          state: "discarded",
          inserted_at: ~U[2026-06-02 10:05:00Z],
          discarded_at: ~U[2026-06-02 10:06:00Z],
          args: %{
            "upstream_identity_id" => "00000000-0000-0000-0000-000000000101",
            "token" => "secret-token-123",
            "prompt" => "raw-prompt-text",
            "request_body" => "request-body-json",
            "auth_json" => "auth-json-refresh-token",
            "websocket_frame" => "websocket-frame-bytes"
          },
          meta: %{
            "cookie" => "cookie-header-value"
          },
          errors: [
            %{
              "at" => DateTime.to_iso8601(~U[2026-06-02 10:06:00Z]),
              "attempt" => 1,
              "error" => "stacktrace-with-secret"
            }
          ]
        )

      retry_job =
        insert_overview_job(3,
          worker: TokenRefreshWorker,
          state: "retryable",
          attempt: 2,
          inserted_at: ~U[2026-06-02 10:10:00Z],
          attempted_at: ~U[2026-06-02 10:11:00Z]
        )

      stuck_job =
        insert_overview_job(4,
          worker: RuntimeStateCleanupWorker,
          state: "executing",
          inserted_at: ~U[2026-06-02 09:55:00Z],
          attempted_at: ~U[2026-06-02 10:20:00Z]
        )

      backlog_job =
        insert_overview_job(5,
          worker: CatalogSyncWorker,
          state: "scheduled",
          inserted_at: ~U[2026-06-02 10:14:00Z],
          scheduled_at: ~U[2026-06-02 10:00:00Z]
        )

      completed_job =
        insert_overview_job(6,
          state: "completed",
          inserted_at: ~U[2026-06-02 10:15:00Z],
          completed_at: ~U[2026-06-02 10:16:00Z]
        )

      assert older_failure.id

      assert %{
               status: :attention_required,
               empty?: false,
               healthy?: false,
               total: 6,
               actionable_count: 5,
               completed_context_count: 1,
               buckets: buckets,
               completed_context: completed_context
             } = ReadModel.jobs_overview(:system, %{}, now: now)

      assert buckets.active_failure.count == 2
      assert buckets.active_failure.newest.id == newest_failure.id

      assert buckets.active_failure.newest.failure_summary == %{
               title: "Attempt 1",
               message: "stacktrace-with-[redacted]"
             }

      assert buckets.retry_pressure.count == 1
      assert buckets.retry_pressure.newest.id == retry_job.id
      assert buckets.stuck_executing.count == 1
      assert buckets.stuck_executing.newest.id == stuck_job.id
      assert buckets.backlog_pressure.count == 1
      assert buckets.backlog_pressure.newest.id == backlog_job.id

      assert completed_context.count == 1
      assert completed_context.newest.id == completed_job.id

      examples =
        buckets
        |> Map.values()
        |> Enum.map(& &1.newest)
        |> Kernel.++([completed_context.newest])

      assert Enum.all?(examples, &safe_overview_job_shape?/1)

      serialized = inspect(ReadModel.jobs_overview(:system, %{}, now: now))
      refute serialized =~ "secret-token-123"
      refute serialized =~ "raw-prompt-text"
      refute serialized =~ "request-body-json"
      refute serialized =~ "cookie-header-value"
      refute serialized =~ "auth-json-refresh-token"
      refute serialized =~ "websocket-frame-bytes"
      refute serialized =~ "stacktrace-with-secret"
    end

    test "reports healthy when jobs exist but only completed context is actionable-free" do
      insert_overview_job(1,
        state: "completed",
        inserted_at: ~U[2026-06-02 10:00:00Z],
        completed_at: ~U[2026-06-02 10:01:00Z]
      )

      assert %{
               status: :healthy,
               empty?: false,
               healthy?: true,
               total: 1,
               actionable_count: 0,
               completed_context_count: 1,
               buckets: buckets,
               completed_context: %{count: 1, newest: %{state: "completed"}}
             } = ReadModel.jobs_overview(:system, %{}, now: ~U[2026-06-02 10:30:00Z])

      assert Enum.all?(Map.values(buckets), &match?(%{count: 0, newest: nil}, &1))
    end

    test "reports empty when no job rows exist" do
      assert %{
               status: :empty,
               empty?: true,
               healthy?: false,
               total: 0,
               actionable_count: 0,
               completed_context_count: 0,
               buckets: buckets,
               completed_context: %{count: 0, newest: nil}
             } = ReadModel.jobs_overview(:system, %{}, now: ~U[2026-06-02 10:30:00Z])

      assert Enum.all?(Map.values(buckets), &match?(%{count: 0, newest: nil}, &1))
    end
  end

  defp insert_overview_job(index, attrs) do
    inserted_at = Keyword.fetch!(attrs, :inserted_at)
    args = Keyword.get(attrs, :args, %{}) |> Map.put_new("index", index)
    meta = Keyword.get(attrs, :meta, %{"source" => "overview-test"})

    assert {:ok, job} =
             args
             |> RuntimeStateCleanupWorker.new(meta: meta, unique: false)
             |> Oban.insert()

    updates =
      attrs
      |> Keyword.take([
        :worker,
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
      ])
      |> Keyword.put_new(:state, "available")
      |> Keyword.put_new(:attempt, 0)
      |> Keyword.put_new(:max_attempts, 20)
      |> maybe_put_worker_name()
      |> Keyword.put(:inserted_at, inserted_at)

    {1, _rows} =
      from(job in Oban.Job, where: job.id == ^job.id)
      |> Repo.update_all(set: updates)

    Repo.get!(Oban.Job, job.id)
  end

  defp maybe_put_worker_name(updates) do
    if Keyword.has_key?(updates, :worker) do
      Keyword.update!(updates, :worker, &worker_name/1)
    else
      updates
    end
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp safe_overview_job_shape?(job) do
    keys = job |> Map.keys() |> MapSet.new()

    MapSet.equal?(keys, MapSet.new(safe_overview_job_keys())) or
      MapSet.equal?(keys, MapSet.new([:failure_summary | safe_overview_job_keys()]))
  end

  defp safe_overview_job_keys do
    [
      :id,
      :state,
      :max_attempts,
      :queue,
      :worker,
      :target,
      :inserted_at,
      :attempt,
      :attention_state,
      :scheduled_at,
      :attempted_at,
      :completed_at,
      :discarded_at,
      :cancelled_at
    ]
  end
end
