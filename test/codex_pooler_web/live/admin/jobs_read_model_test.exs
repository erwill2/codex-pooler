defmodule CodexPoolerWeb.Admin.JobsReadModelTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Jobs.{RuntimeStateCleanupWorker, TokenRefreshWorker}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.JobsReadModel

  import CodexPooler.AccountsFixtures

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "loads one owner-only overview explorer projection with normalized filters and selected job" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner, ["instance_owner"])
    now = ~U[2026-06-02 10:30:00Z]

    selected_job =
      insert_job(1,
        worker: TokenRefreshWorker,
        queue: "jobs",
        state: "retryable",
        attempt: 3,
        inserted_at: ~U[2026-06-02 10:00:00Z],
        attempted_at: ~U[2026-06-02 10:01:00Z],
        args: %{
          "token" => "secret-token-123",
          "prompt" => "raw-prompt-text",
          "request_body" => "request-body-json",
          "auth_json" => "auth-json-refresh-token",
          "websocket_frame" => "websocket-frame-bytes"
        },
        meta: %{"cookie" => "cookie-header-value"},
        errors: [
          %{
            "at" => DateTime.to_iso8601(~U[2026-06-02 10:02:00Z]),
            "attempt" => 1,
            "error" => "stacktrace-with-secret"
          }
        ]
      )

    completed_job =
      insert_job(2,
        worker: RuntimeStateCleanupWorker,
        state: "completed",
        inserted_at: ~U[2026-06-02 10:10:00Z],
        completed_at: ~U[2026-06-02 10:11:00Z]
      )

    projection =
      JobsReadModel.load(owner_scope,
        params: %{
          "worker" => worker_name(TokenRefreshWorker),
          "queue" => "jobs",
          "job_id" => Integer.to_string(selected_job.id)
        },
        now: now
      )

    assert %{
             overview: overview,
             explorer: explorer,
             filters: filters,
             form_values: form_values,
             filter_options: filter_options,
             filter_warnings: [],
             selected_job: %{id: selected_id}
           } = projection

    assert selected_id == selected_job.id
    assert overview.status == :attention_required
    assert overview.total == 1
    assert explorer == %{items: [projection.selected_job], total: 1, limit: 50, offset: 0}
    assert filters.worker == worker_name(TokenRefreshWorker)
    assert filters.queue == "jobs"
    assert filters.job_id == selected_job.id
    assert form_values["job_id"] == Integer.to_string(selected_job.id)
    assert filter_options.worker |> Enum.map(& &1.value) == ["", worker_name(TokenRefreshWorker)]
    assert filter_options.queue |> Enum.map(& &1.value) == ["", "jobs"]

    refute Enum.any?(projection.explorer.items, &(&1.id == completed_job.id))
    refute Map.has_key?(projection, :recent_jobs)

    serialized = inspect(projection)
    refute serialized =~ "secret-token-123"
    refute serialized =~ "raw-prompt-text"
    refute serialized =~ "request-body-json"
    refute serialized =~ "auth-json-refresh-token"
    refute serialized =~ "websocket-frame-bytes"
    refute serialized =~ "cookie-header-value"
    refute serialized =~ "stacktrace-with-secret"
    refute serialized =~ ":args"
    refute serialized =~ ":meta"
    refute serialized =~ ":errors"
  end

  test "returns selected_job nil when normalized job_id is absent from the filtered page" do
    hidden_completed_job =
      insert_job(1,
        state: "completed",
        inserted_at: ~U[2026-06-02 10:00:00Z],
        completed_at: ~U[2026-06-02 10:01:00Z]
      )

    projection =
      JobsReadModel.load(:system,
        params: %{"job_id" => Integer.to_string(hidden_completed_job.id)},
        now: ~U[2026-06-02 10:30:00Z]
      )

    assert projection.explorer.items == []
    assert projection.selected_job == nil
    assert projection.filters.job_id == hidden_completed_job.id
  end

  test "default projection excludes discarded jobs resolved by a later target success" do
    resolved_target_id = Ecto.UUID.generate()
    unresolved_target_id = Ecto.UUID.generate()

    resolved_failure =
      insert_job(1,
        worker: TokenRefreshWorker,
        state: "discarded",
        inserted_at: ~U[2026-06-02 10:00:00Z],
        discarded_at: ~U[2026-06-02 10:01:00Z],
        args: %{"upstream_identity_id" => resolved_target_id}
      )

    insert_job(2,
      worker: TokenRefreshWorker,
      state: "completed",
      inserted_at: ~U[2026-06-02 10:05:00Z],
      completed_at: ~U[2026-06-02 10:06:00Z],
      args: %{"upstream_identity_id" => resolved_target_id}
    )

    unresolved_failure =
      insert_job(3,
        worker: TokenRefreshWorker,
        state: "discarded",
        inserted_at: ~U[2026-06-02 10:10:00Z],
        discarded_at: ~U[2026-06-02 10:11:00Z],
        args: %{"upstream_identity_id" => unresolved_target_id}
      )

    projection =
      JobsReadModel.load(:system,
        params: %{},
        now: ~U[2026-06-02 10:30:00Z]
      )

    assert projection.overview.actionable_count == 1
    assert projection.overview.buckets.active_failure.count == 1
    assert Enum.map(projection.explorer.items, & &1.id) == [unresolved_failure.id]
    refute Enum.any?(projection.explorer.items, &(&1.id == resolved_failure.id))
  end

  test "keeps invalid URL filter warnings while applying safe defaults" do
    projection =
      JobsReadModel.load(:system,
        params: %{"state" => "completed", "page" => "0", "job_id" => "not-an-id"}
      )

    assert projection.filters.state == nil
    assert projection.filters.page == 1
    assert projection.filters.job_id == nil
    assert projection.form_values["state"] == "completed"
    assert projection.form_values["page"] == "1"

    assert %{field: :state, message: "Completed jobs require show_completed=true"} in projection.filter_warnings

    assert %{field: :page, message: "Page must be a positive integer"} in projection.filter_warnings

    assert %{field: :job_id, message: "Job id must be a positive integer"} in projection.filter_warnings
  end

  test "returns a safe empty projection for non-owner scopes without global leakage" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner, ["instance_owner"])

    global_job =
      insert_job(1,
        worker: TokenRefreshWorker,
        state: "retryable",
        inserted_at: ~U[2026-06-02 10:00:00Z],
        attempted_at: ~U[2026-06-02 10:01:00Z]
      )

    %{user: admin} = operator_fixture(owner_scope, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin, ["instance_admin"])

    projection =
      JobsReadModel.load(admin_scope,
        params: %{
          "job_id" => Integer.to_string(global_job.id),
          "worker" => worker_name(TokenRefreshWorker)
        }
      )

    assert projection.overview.empty?
    assert projection.overview.total == 0
    assert projection.explorer == %{items: [], total: 0, limit: 50, offset: 0}
    assert projection.selected_job == nil
    refute Map.has_key?(projection, :recent_jobs)
    assert projection.filter_warnings == []
    assert projection.filters.job_id == nil
    assert projection.filters.worker == nil
    assert projection.form_values["job_id"] == ""
    assert projection.form_values["worker"] == ""
    refute inspect(projection) =~ Integer.to_string(global_job.id)
  end

  defp insert_job(index, attrs) do
    inserted_at = Keyword.fetch!(attrs, :inserted_at)
    args = Keyword.get(attrs, :args, %{}) |> Map.put_new("index", index)
    meta = Keyword.get(attrs, :meta, %{"source" => "jobs-read-model-test"})

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

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
end
