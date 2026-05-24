defmodule CodexPoolerWeb.Admin.JobsLiveTableTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Jobs.CatalogSyncWorker
  alias CodexPooler.Jobs.RuntimeStateCleanupWorker
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "renders exactly one sidebar Jobs entry", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(
             view,
             "#admin-nav-jobs[aria-current='page'][href='/admin/jobs']",
             "System Jobs"
           )

    assert render(view) |> count_occurrences(~s(id="admin-nav-jobs")) == 1
  end

  test "renders empty state when no jobs exist", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, "#admin-jobs-worker-grid")
    assert has_element?(view, worker_card_selector(:catalog_sync), "Awaiting first run")
    assert has_element?(view, worker_card_selector(:token_refresh), "No observed run")
    assert has_element?(view, "#admin-jobs-empty-state", "No jobs recorded")
    refute has_element?(view, "#admin-jobs-table")
  end

  test "worker cards use worker-specific history beyond the recent global slice", %{conn: conn} do
    catalog_job =
      insert_job(
        1,
        worker: CatalogSyncWorker,
        state: "completed",
        inserted_at: ~U[2026-05-04 10:00:00Z],
        completed_at: ~U[2026-05-04 10:01:00Z]
      )

    for index <- 2..56 do
      insert_job(index,
        worker: AccountReconciliationWorker,
        state: "completed",
        inserted_at: DateTime.add(~U[2026-05-04 11:00:00Z], index, :second),
        completed_at: DateTime.add(~U[2026-05-04 11:01:00Z], index, :second)
      )
    end

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    refute has_element?(view, "#job-#{catalog_job.id}")
    assert has_element?(view, worker_card_selector(:catalog_sync), "Completed")
    assert has_element?(view, worker_card_selector(:catalog_sync), "10:01:00 UTC")
  end

  test "worker cards show the next scheduled job when one is queued", %{conn: conn} do
    scheduled_at =
      DateTime.utc_now() |> DateTime.add(1_200, :second) |> DateTime.truncate(:second)

    insert_job(
      1,
      worker: TokenRefreshWorker,
      state: "scheduled",
      inserted_at: DateTime.add(scheduled_at, -60, :second),
      scheduled_at: scheduled_at
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, worker_card_selector(:token_refresh), "Next run")
    assert has_element?(view, "#{worker_card_selector(:token_refresh)} [data-role='next-run']")
  end

  test "renders uncommon state and missing timestamps safely", %{conn: conn} do
    job =
      insert_job(
        1,
        state: "suspended",
        inserted_at: ~U[2026-05-04 11:00:00Z],
        attempted_at: nil,
        completed_at: nil,
        discarded_at: nil,
        cancelled_at: nil
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, state_icon_selector(job, "Suspended"))
    assert has_element?(view, "#job-#{job.id}", "-")
    refute has_element?(view, "#job-#{job.id}", "not recorded")
  end

  test "represents known job states with row icons", %{conn: conn} do
    base_time = ~U[2026-05-04 12:00:00Z]

    expected_states = [
      {"available", "Available"},
      {"scheduled", "Scheduled"},
      {"executing", "Executing"},
      {"retryable", "Retryable"},
      {"completed", "Completed"},
      {"discarded", "Discarded"},
      {"cancelled", "Cancelled"}
    ]

    jobs =
      for {{state, label}, index} <- Enum.with_index(expected_states, 1) do
        job =
          insert_job(index,
            state: state,
            inserted_at: DateTime.add(base_time, index, :second)
          )

        {job, label}
      end

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    for {job, label} <- jobs do
      assert has_element?(view, state_icon_selector(job, label))
    end
  end

  test "does not render job mutation controls", %{conn: conn} do
    insert_job(1, inserted_at: ~U[2026-05-04 12:00:00Z])
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    for label <- ["Retry", "Cancel", "Discard", "Delete"] do
      refute has_element?(view, "button", label)
      refute has_element?(view, "a", label)
    end
  end

  defp insert_job(index, attrs) do
    inserted_at = Keyword.fetch!(attrs, :inserted_at)
    args = Keyword.get(attrs, :args, %{"index" => index})
    meta = Keyword.get(attrs, :meta, %{"source" => "admin-jobs-live-test"})

    assert {:ok, job} =
             args
             |> RuntimeStateCleanupWorker.new(meta: meta)
             |> Oban.insert()

    updates =
      attrs
      |> Keyword.take([
        :worker,
        :state,
        :attempt,
        :max_attempts,
        :inserted_at,
        :scheduled_at,
        :attempted_at,
        :completed_at,
        :discarded_at,
        :cancelled_at,
        :errors
      ])
      |> maybe_put_worker_name()
      |> Keyword.put(:inserted_at, inserted_at)

    {1, _rows} =
      from(job in Oban.Job, where: job.id == ^job.id)
      |> Repo.update_all(set: updates)

    Repo.get!(Oban.Job, job.id)
  end

  defp state_icon_selector(job, label) do
    "#job-#{job.id} [data-role='state-icon'][aria-label='State: #{label}']"
  end

  defp worker_card_selector(worker_group) do
    "#job-worker-card-#{String.replace(Atom.to_string(worker_group), "_", "-")}"
  end

  defp count_occurrences(source, pattern) do
    source
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
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
