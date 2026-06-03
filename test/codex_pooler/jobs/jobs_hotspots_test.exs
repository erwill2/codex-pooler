defmodule CodexPooler.Jobs.JobsHotspotsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Jobs.ReadModel

  alias CodexPooler.Jobs.{
    CatalogSyncWorker,
    DailyRollupRebuildWorker,
    RuntimeStateCleanupWorker,
    TokenRefreshWorker
  }

  alias CodexPooler.Repo

  import CodexPooler.PoolerFixtures

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  describe "jobs hotspots" do
    test "ranks worker, queue, account, pool, and target concentrations from actionable jobs only" do
      now = ~U[2026-06-02 10:30:00Z]
      pool = pool_fixture(%{name: "Operations Pool", slug: "operations-pool"})

      %{identity: dominant_identity, assignment: dominant_assignment} =
        upstream_assignment_fixture(pool, %{
          account_label: "Dominant upstream",
          assignment_label: "Dominant assignment"
        })

      %{identity: secondary_identity} =
        upstream_assignment_fixture(pool, %{
          account_label: "Secondary upstream",
          assignment_label: "Secondary assignment"
        })

      for index <- 1..3 do
        insert_hotspot_job(index,
          worker: TokenRefreshWorker,
          queue: "jobs",
          state: "retryable",
          attempt: 2,
          inserted_at: DateTime.add(~U[2026-06-02 10:00:00Z], index, :second),
          attempted_at: DateTime.add(~U[2026-06-02 10:05:00Z], index, :second),
          args: %{
            "pool_id" => pool.id,
            "pool_upstream_assignment_id" => dominant_assignment.id
          }
        )
      end

      insert_hotspot_job(4,
        worker: CatalogSyncWorker,
        queue: "catalog",
        state: "discarded",
        inserted_at: ~U[2026-06-02 10:10:00Z],
        discarded_at: ~U[2026-06-02 10:11:00Z],
        args: %{"pool_id" => pool.id, "upstream_identity_id" => secondary_identity.id}
      )

      insert_hotspot_job(5,
        worker: RuntimeStateCleanupWorker,
        queue: "jobs",
        state: "completed",
        inserted_at: ~U[2026-06-02 10:12:00Z],
        completed_at: ~U[2026-06-02 10:13:00Z],
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => dominant_assignment.id
        }
      )

      assert %{
               actionable_count: 4,
               workers: [dominant_worker, secondary_worker],
               queues: [jobs_queue, catalog_queue],
               pools: [pool_hotspot],
               accounts: [dominant_account, secondary_account],
               targets: [dominant_target | _targets]
             } = ReadModel.jobs_hotspots(:system, %{}, now: now)

      assert dominant_worker == %{
               worker: worker_name(TokenRefreshWorker),
               label: "TokenRefresh",
               count: 3
             }

      assert secondary_worker == %{
               worker: worker_name(CatalogSyncWorker),
               label: "CatalogSync",
               count: 1
             }

      assert jobs_queue == %{queue: "jobs", label: "jobs", count: 3}
      assert catalog_queue == %{queue: "catalog", label: "catalog", count: 1}
      assert pool_hotspot == %{id: pool.id, label: "Operations Pool", count: 4}

      assert dominant_account == %{
               id: dominant_identity.id,
               label: "Dominant upstream",
               count: 3
             }

      assert secondary_account == %{
               id: secondary_identity.id,
               label: "Secondary upstream",
               count: 1
             }

      assert dominant_target == %{
               kind: :assignment,
               id: dominant_assignment.id,
               label: "Dominant assignment",
               count: 3
             }
    end

    test "keeps deleted or missing targets visible through safe fallback labels" do
      now = ~U[2026-06-02 10:30:00Z]
      missing_assignment_id = Ecto.UUID.generate()
      missing_account_id = Ecto.UUID.generate()
      missing_pool_id = Ecto.UUID.generate()
      missing_api_key_id = Ecto.UUID.generate()

      insert_hotspot_job(1,
        state: "discarded",
        inserted_at: ~U[2026-06-02 10:00:00Z],
        discarded_at: ~U[2026-06-02 10:01:00Z],
        args: %{"pool_upstream_assignment_id" => missing_assignment_id}
      )

      insert_hotspot_job(2,
        state: "discarded",
        inserted_at: ~U[2026-06-02 10:02:00Z],
        discarded_at: ~U[2026-06-02 10:03:00Z],
        args: %{"upstream_identity_id" => missing_account_id}
      )

      insert_hotspot_job(3,
        state: "discarded",
        inserted_at: ~U[2026-06-02 10:04:00Z],
        discarded_at: ~U[2026-06-02 10:05:00Z],
        args: %{"pool_id" => missing_pool_id}
      )

      insert_hotspot_job(4,
        state: "discarded",
        inserted_at: ~U[2026-06-02 10:06:00Z],
        discarded_at: ~U[2026-06-02 10:07:00Z],
        args: %{"api_key_id" => missing_api_key_id}
      )

      insert_hotspot_job(5,
        worker: DailyRollupRebuildWorker,
        state: "discarded",
        inserted_at: ~U[2026-06-02 10:08:00Z],
        discarded_at: ~U[2026-06-02 10:09:00Z],
        args: %{"rollup_date" => "2026-06-01"}
      )

      insert_hotspot_job(6,
        state: "discarded",
        inserted_at: ~U[2026-06-02 10:10:00Z],
        discarded_at: ~U[2026-06-02 10:11:00Z]
      )

      hotspots = ReadModel.jobs_hotspots(:system, %{}, now: now)

      assert %{id: ^missing_pool_id, label: "Pool unavailable", count: 1} =
               Enum.find(hotspots.pools, &(&1.id == missing_pool_id))

      assert %{id: ^missing_account_id, label: "Account unavailable", count: 1} =
               Enum.find(hotspots.accounts, &(&1.id == missing_account_id))

      assert %{kind: :assignment, id: ^missing_assignment_id, label: "Assignment unavailable"} =
               Enum.find(hotspots.targets, &(&1.kind == :assignment))

      assert %{kind: :upstream_identity, id: ^missing_account_id, label: "Account unavailable"} =
               Enum.find(hotspots.targets, &(&1.kind == :upstream_identity))

      assert %{kind: :pool, id: ^missing_pool_id, label: "Pool unavailable"} =
               Enum.find(hotspots.targets, &(&1.kind == :pool))

      assert %{kind: :api_key, id: ^missing_api_key_id, label: "API key unavailable"} =
               Enum.find(hotspots.targets, &(&1.kind == :api_key))

      assert %{kind: :rollup_date, id: "2026-06-01", label: "Rollup date 2026-06-01"} =
               Enum.find(hotspots.targets, &(&1.kind == :rollup_date))

      assert %{kind: :system, id: nil, label: "System job"} =
               Enum.find(hotspots.targets, &(&1.kind == :system))
    end

    test "bounds each ranked collection and keeps projection metadata-only" do
      now = ~U[2026-06-02 10:30:00Z]

      for index <- 1..7 do
        insert_hotspot_job(index,
          worker: "Example.Worker#{index}",
          queue: "queue-#{index}",
          state: "retryable",
          inserted_at: DateTime.add(~U[2026-06-02 10:00:00Z], index, :second),
          attempted_at: DateTime.add(~U[2026-06-02 10:01:00Z], index, :second),
          args: %{
            "upstream_identity_id" => Ecto.UUID.generate(),
            "token" => "secret-token-#{index}",
            "prompt" => "raw-prompt-#{index}",
            "request_body" => "request-body-#{index}",
            "auth_json" => "auth-json-#{index}",
            "websocket_frame" => "frame-#{index}"
          },
          meta: %{"cookie" => "cookie-#{index}"},
          errors: [
            %{
              "at" => DateTime.to_iso8601(~U[2026-06-02 10:02:00Z]),
              "attempt" => 1,
              "error" => "stacktrace-with-secret-#{index}"
            }
          ]
        )
      end

      hotspots = ReadModel.jobs_hotspots(:system, %{}, now: now)

      assert hotspots.actionable_count == 7
      assert length(hotspots.workers) == 5
      assert length(hotspots.queues) == 5
      assert length(hotspots.accounts) == 5
      assert length(hotspots.targets) == 6

      serialized = inspect(hotspots)
      refute serialized =~ "secret-token"
      refute serialized =~ "raw-prompt"
      refute serialized =~ "request-body"
      refute serialized =~ "auth-json"
      refute serialized =~ "frame-"
      refute serialized =~ "cookie-"
      refute serialized =~ "stacktrace-with-secret"
    end
  end

  defp insert_hotspot_job(index, attrs) do
    inserted_at = Keyword.fetch!(attrs, :inserted_at)
    args = Keyword.get(attrs, :args, %{}) |> Map.put_new("index", index)
    meta = Keyword.get(attrs, :meta, %{"source" => "hotspots-test"})

    assert {:ok, job} =
             args
             |> RuntimeStateCleanupWorker.new(meta: meta, unique: false)
             |> Oban.insert()

    updates =
      attrs
      |> Keyword.take([
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

  defp worker_name(worker) when is_atom(worker),
    do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp worker_name(worker) when is_binary(worker), do: worker
end
