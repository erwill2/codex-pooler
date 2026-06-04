defmodule CodexPoolerWeb.Admin.JobsLiveWorkerCardsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Jobs.CatalogSyncWorker
  alias CodexPooler.Jobs.RuntimeStateCleanupWorker
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.AvatarComponents

  setup :register_and_log_in_user

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "worker cards render active markers and unresolved failure dialogs by target", %{
    conn: conn
  } do
    active_pool = pool_fixture(%{name: "Active Pool", slug: "active-pool"})
    failing_pool = pool_fixture(%{name: "Failing Pool", slug: "failing-pool"})
    resolved_pool = pool_fixture(%{name: "Resolved Pool", slug: "resolved-pool"})

    active_job =
      insert_job(
        1,
        worker: CatalogSyncWorker,
        state: "executing",
        inserted_at: ~U[2026-05-04 10:00:00Z],
        attempted_at: ~U[2026-05-04 10:00:30Z],
        args: %{"pool_id" => active_pool.id}
      )

    failing_job =
      insert_job(
        2,
        worker: CatalogSyncWorker,
        state: "discarded",
        inserted_at: ~U[2026-05-04 10:01:00Z],
        discarded_at: ~U[2026-05-04 10:02:00Z],
        args: %{"pool_id" => failing_pool.id},
        errors: [
          %{
            "attempt" => 3,
            "kind" => "RuntimeError",
            "error" => "catalog sync timeout authorization=Bearer secret-token-123"
          }
        ]
      )

    resolved_failure =
      insert_job(
        3,
        worker: CatalogSyncWorker,
        state: "discarded",
        inserted_at: ~U[2026-05-04 10:03:00Z],
        discarded_at: ~U[2026-05-04 10:04:00Z],
        args: %{"pool_id" => resolved_pool.id},
        errors: [
          %{
            "attempt" => 1,
            "kind" => "RuntimeError",
            "error" => "resolved failure"
          }
        ]
      )

    insert_job(
      4,
      worker: CatalogSyncWorker,
      state: "completed",
      inserted_at: ~U[2026-05-04 10:05:00Z],
      completed_at: ~U[2026-05-04 10:06:00Z],
      args: %{"pool_id" => resolved_pool.id}
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:catalog_sync)

    assert has_element?(view, "#{card} [data-role='worker-activity-strip']")

    assert has_element?(
             view,
             "#{card} #job-activity-#{active_job.id}[aria-label*='CatalogSync']"
           )

    assert has_element?(
             view,
             "#{card} #job-activity-#{active_job.id}[aria-label*='Active Pool']"
           )

    assert has_element?(
             view,
             "#{card} #job-activity-#{active_job.id} [data-role='target-initial']",
             "AP"
           )

    refute has_element?(view, "#{card} [data-role='worker-activity-strip'] .loading-spinner")

    assert has_element?(
             view,
             "#{card} #job-failure-#{failing_job.id}[aria-label*='Failing Pool']"
           )

    assert has_element?(view, "#{card} #job-failure-dialog-#{failing_job.id}")
    assert has_element?(view, "#{card} #job-failure-dialog-#{failing_job.id}", "RuntimeError")

    assert has_element?(
             view,
             "#{card} #job-failure-dialog-#{failing_job.id}",
             "catalog sync timeout"
           )

    refute has_element?(view, "#{card} #job-failure-#{resolved_failure.id}")

    rendered = render(view)
    refute rendered =~ "secret-token-123"
    refute rendered =~ "Bearer secret-token"
  end

  test "worker cards use short copy and compact schedule facts", %{conn: conn} do
    job =
      insert_job(
        1,
        worker: RuntimeStateCleanupWorker,
        state: "completed",
        attempt: 2,
        max_attempts: 5,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        completed_at: ~U[2026-05-04 10:02:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs?show_completed=true")
    card = worker_card_selector(:runtime_cleanup)

    assert has_element?(view, "#{card}", "Expired state cleanup")

    assert has_element?(
             view,
             "#{card} [data-role='worker-state-badge'].rounded-full",
             "Completed"
           )

    refute has_element?(view, "#{card} [data-role='state-icon']")

    assert has_element?(
             view,
             "#{card} [data-role='worker-schedule-facts'][data-density='compact']"
           )

    assert has_element?(view, "#{card} [data-role='next-run-group']", "Next run")
    assert has_element?(view, "#{card} [data-role='last-run']", "2026-05-04 10:02:00 UTC")
    assert has_element?(view, "#{card} [data-role='schedule']", "Schedule")

    assert has_element?(
             view,
             "#{card} [data-role='schedule'] [data-role='cadence-label']",
             "Every 15 min"
           )

    refute has_element?(
             view,
             "#{card} [data-role='worker-schedule-facts'] [data-role='attempts']"
           )

    refute has_element?(view, "#{card}", "Last success")
    refute has_element?(view, "#{card}", "Last failure")
    refute has_element?(view, "#{card} [data-role='last-success']")
    refute has_element?(view, "#{card} [data-role='last-failure']")

    rendered = render(view)

    assert rendered =~ "border-success/20 bg-success/10"
    assert rendered =~ ~s(data-role="worker-schedule-grid")

    assert rendered =~ "Model catalog refresh"
    assert rendered =~ "Pricing data refresh"
    assert rendered =~ "Upstream account checks"
    assert rendered =~ "Alert rule checks"
    assert rendered =~ "Access-token renewal"
    assert rendered =~ "Usage rollup rebuild"
    refute rendered =~ "Expired files, sessions, runtime state, and stale reconciliation cleanup"
    refute rendered =~ "OpenAI pricing JSON catalog refreshes"
    refute rendered =~ "Quota, health, token, and catalog checks"
    assert has_element?(view, "#job-#{job.id}")
  end

  test "account reconciliation card renders one compact active marker per assignment", %{
    conn: conn
  } do
    pool = pool_fixture(%{name: "Fanout Pool", slug: "fanout-pool"})

    %{assignment: first_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "codex01@example.com",
        assignment_label: "codex01@example.com"
      })

    %{assignment: second_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "codex02@example.com",
        assignment_label: "codex02@example.com"
      })

    first_job =
      insert_job(
        1,
        worker: AccountReconciliationWorker,
        state: "executing",
        inserted_at: ~U[2026-05-04 10:00:00Z],
        attempted_at: ~U[2026-05-04 10:00:30Z],
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => first_assignment.id,
          "trigger_kind" => "scheduled"
        }
      )

    second_job =
      insert_job(
        2,
        worker: AccountReconciliationWorker,
        state: "executing",
        inserted_at: ~U[2026-05-04 10:00:01Z],
        attempted_at: ~U[2026-05-04 10:00:31Z],
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => second_assignment.id,
          "trigger_kind" => "scheduled"
        }
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:account_reconciliation)
    rendered = render(view)

    assert has_element?(view, "#{card} [data-role='worker-activity-strip']")
    assert has_element?(view, "#{card} [data-role='worker-live-dot']")
    refute rendered =~ "Account fan-out slots are always visible"
    refute rendered =~ "Empty slots stay reserved"
    refute rendered =~ "job-target-board"

    assert has_element?(
             view,
             "#{card} #job-activity-#{first_job.id}[aria-label*='codex01@example.com']"
           )

    assert has_element?(
             view,
             "#{card} #job-activity-#{second_job.id}[aria-label*='codex02@example.com']"
           )

    assert has_element?(
             view,
             "#{card} #job-activity-#{first_job.id}[data-has-avatar='true'] .avatar img[src='#{AvatarComponents.gravatar_url("codex01@example.com", size: 64)}']"
           )

    assert has_element?(
             view,
             "#{card} #job-activity-#{second_job.id}[data-has-avatar='true'] .avatar img[src='#{AvatarComponents.gravatar_url("codex02@example.com", size: 64)}']"
           )

    refute has_element?(view, "#{card} #job-activity-#{first_job.id} > img")

    refute has_element?(
             view,
             "#{card} #job-activity-#{first_job.id} [data-role='target-initial']"
           )

    refute has_element?(view, "#{card} [data-role='worker-activity-strip'] .loading-spinner")
    refute has_element?(view, "#{card} #job-activity-#{first_job.id}", "AccountReconciliation")
    refute has_element?(view, "#{card} #job-activity-#{first_job.id}", "codex01@example.com")
    refute has_element?(view, "#{card} #job-activity-#{second_job.id}", "codex02@example.com")
  end

  test "account reconciliation failure markers use the shared avatar component", %{conn: conn} do
    pool = pool_fixture(%{name: "Failure Avatar Pool", slug: "failure-avatar-pool"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "failed-account@example.com",
        assignment_label: "failed-account@example.com"
      })

    job =
      insert_job(
        1,
        worker: AccountReconciliationWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 1,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        discarded_at: ~U[2026-05-04 10:00:30Z],
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => assignment.id,
          "trigger_kind" => "scheduled"
        },
        errors: [
          %{
            "attempt" => 1,
            "error" => "account reconciliation partial: quota_refresh_failed"
          }
        ]
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:account_reconciliation)

    assert has_element?(
             view,
             "#{card} #job-failure-#{job.id}[data-has-avatar='true'] .avatar img[src='#{AvatarComponents.gravatar_url("failed-account@example.com", size: 64)}']"
           )

    refute has_element?(view, "#{card} #job-failure-#{job.id} > img")
  end

  test "account reconciliation card caps active target markers", %{conn: conn} do
    pool = pool_fixture(%{name: "Fanout Pool", slug: "fanout-pool"})

    for index <- 1..10 do
      insert_job(
        index,
        worker: AccountReconciliationWorker,
        state: "executing",
        inserted_at: DateTime.add(~U[2026-05-04 10:00:00Z], index, :second),
        attempted_at: DateTime.add(~U[2026-05-04 10:00:30Z], index, :second),
        args: %{
          "pool_id" => pool.id,
          "pool_upstream_assignment_id" => "target-#{index}",
          "trigger_kind" => "scheduled"
        }
      )
    end

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:account_reconciliation)
    rendered = render(view)

    assert count_occurrences(rendered, "data-role=\"active-worker-marker\"") == 8
    assert has_element?(view, "#{card} [data-role='active-worker-overflow']", "+2")
    refute rendered =~ "Account fan-out slots are always visible"
  end

  test "renders redacted failure details for failed jobs", %{conn: conn} do
    job =
      insert_job(
        1,
        worker: AccountReconciliationWorker,
        state: "discarded",
        attempt: 1,
        max_attempts: 1,
        inserted_at: ~U[2026-05-04 10:00:00Z],
        errors: [
          %{
            "attempt" => 1,
            "kind" => "RuntimeError",
            "error" =>
              "upstream timeout authorization=Bearer secret-token-123 prompt=raw-prompt-text"
          }
        ],
        args: %{"prompt" => "raw-arg-prompt"},
        meta: %{"authorization" => "meta-bearer-value"}
      )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(
             view,
             "#{worker_card_selector(:account_reconciliation)} #job-failure-#{job.id}[aria-label*='AccountReconciliation']"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:account_reconciliation)} #job-failure-dialog-#{job.id}",
             "RuntimeError"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:account_reconciliation)} #job-failure-dialog-#{job.id} [data-role='failure-message']",
             "upstream timeout"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:account_reconciliation)} [data-role='worker-latest-failure']",
             "Latest failure"
           )

    assert has_element?(
             view,
             "#{worker_card_selector(:account_reconciliation)} [data-role='worker-latest-failure']",
             "upstream timeout"
           )

    assert has_element?(view, "#job-#{job.id} [data-role='failure-details']", "Attempt 1")
    assert has_element?(view, "#job-#{job.id} [data-role='failure-details']", "RuntimeError")

    assert has_element?(
             view,
             "#job-#{job.id} [data-role='failure-message']",
             "upstream timeout"
           )

    rendered = render(view)
    refute rendered =~ "secret-token-123"
    refute rendered =~ "secret-token"
    refute rendered =~ "raw-prompt-text"
    refute rendered =~ "raw-arg-prompt"
    refute rendered =~ "meta-bearer-value"
  end

  test "account reconciliation failures use operator-facing copy", %{conn: conn} do
    insert_job(
      1,
      worker: AccountReconciliationWorker,
      state: "discarded",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-05-04 10:00:00Z],
      errors: [
        %{
          "attempt" => 1,
          "error" =>
            "** (Oban.PerformError) CodexPooler.Jobs.AccountReconciliationWorker failed with {:error, \"account reconciliation partial: quota_refresh_auth_unavailable\"}"
        }
      ]
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:account_reconciliation)

    assert has_element?(
             view,
             "#{card} [data-role='worker-latest-failure']",
             "Quota refresh needs account reauthentication."
           )

    assert has_element?(
             view,
             "#{card} [data-role='failed-worker-dialog']",
             "Quota refresh blocked"
           )

    rendered = render(view)
    refute rendered =~ "Oban.PerformError"
    refute rendered =~ "account reconciliation partial: quota_refresh_auth_unavailable"
  end

  test "reauth-required account reconciliation failures are not unresolved targets", %{
    conn: conn
  } do
    pool = pool_fixture(%{name: "Recovery Pool", slug: "recovery-pool"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "recovery@example.com",
        assignment_label: "Recovery account",
        identity_status: "reauth_required",
        assignment_health_status: "disabled",
        assignment_eligibility_status: "ineligible",
        identity_metadata: %{
          "token_refresh" => %{
            "status" => "reauth_required",
            "reason" => %{"code" => "missing_refresh_token"}
          }
        }
      })

    insert_job(
      1,
      worker: AccountReconciliationWorker,
      state: "discarded",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-05-04 10:00:00Z],
      discarded_at: ~U[2026-05-04 10:00:30Z],
      args: %{
        "pool_id" => pool.id,
        "pool_upstream_assignment_id" => assignment.id,
        "trigger_kind" => "scheduled"
      },
      errors: [
        %{
          "attempt" => 1,
          "error" =>
            "** (Oban.PerformError) CodexPooler.Jobs.AccountReconciliationWorker failed with {:error, \"account reconciliation partial: quota_refresh_auth_unavailable\"}"
        }
      ]
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:account_reconciliation)

    refute has_element?(view, "#{card} [data-role='failed-worker-marker']")
    refute has_element?(view, "#{card} [data-role='failed-worker-overflow']")
  end

  test "resolved account reconciliation failures do not render the latest failure panel", %{
    conn: conn
  } do
    pool = pool_fixture(%{name: "Recovered Pool", slug: "recovered-pool"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "recovered@example.com",
        assignment_label: "Recovered account"
      })

    args = %{
      "pool_id" => pool.id,
      "pool_upstream_assignment_id" => assignment.id,
      "trigger_kind" => "scheduled"
    }

    insert_job(
      1,
      worker: AccountReconciliationWorker,
      state: "discarded",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-05-04 10:00:00Z],
      discarded_at: ~U[2026-05-04 10:00:30Z],
      args: args,
      errors: [
        %{
          "attempt" => 1,
          "error" =>
            "** (Oban.PerformError) CodexPooler.Jobs.AccountReconciliationWorker failed with {:error, \"account reconciliation partial: quota_refresh_auth_unavailable\"}"
        }
      ]
    )

    insert_job(
      2,
      worker: AccountReconciliationWorker,
      state: "completed",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-05-04 10:01:00Z],
      completed_at: ~U[2026-05-04 10:01:30Z],
      args: args
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:account_reconciliation)

    refute has_element?(view, "#{card} [data-role='worker-latest-failure']")
    refute has_element?(view, "#{card} [data-role='failed-worker-marker']")
  end

  test "map-shaped oban errors use operator-facing copy", %{conn: conn} do
    insert_job(
      1,
      worker: CatalogSyncWorker,
      state: "discarded",
      attempt: 1,
      max_attempts: 1,
      inserted_at: ~U[2026-05-04 10:00:00Z],
      errors: [
        %{
          "attempt" => 1,
          "error" =>
            "** (Oban.PerformError) CodexPooler.Jobs.CatalogSyncWorker failed with {:error, %{code: :catalog_sync_failed, message: \"upstream secret could not be decrypted\"}}"
        }
      ]
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:catalog_sync)

    assert has_element?(
             view,
             "#{card} [data-role='worker-latest-failure']",
             "upstream [redacted] could not be decrypted"
           )

    assert has_element?(
             view,
             "#{card} [data-role='failed-worker-dialog']",
             "Catalog sync failed"
           )

    rendered = render(view)
    refute rendered =~ "Oban.PerformError"
    refute rendered =~ "catalog_sync_failed"
    refute rendered =~ "upstream secret"
  end

  test "discard oban errors use operator-facing copy", %{conn: conn} do
    insert_job(
      1,
      worker: TokenRefreshWorker,
      state: "discarded",
      attempt: 1,
      max_attempts: 8,
      inserted_at: ~U[2026-05-04 10:00:00Z],
      errors: [
        %{
          "attempt" => 1,
          "error" =>
            "** (Oban.PerformError) CodexPooler.Jobs.TokenRefreshWorker failed with :discard"
        }
      ]
    )

    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    card = worker_card_selector(:token_refresh)

    assert has_element?(
             view,
             "#{card} [data-role='worker-latest-failure']",
             "The job stopped without additional diagnostics."
           )

    assert has_element?(
             view,
             "#{card} [data-role='worker-latest-failure'] > div > [data-role='latest-failure-message']",
             "The job stopped without additional diagnostics."
           )

    assert has_element?(
             view,
             "#{card} [data-role='latest-failure-summary'] [data-role='latest-failure-meta']"
           )

    refute has_element?(view, "#{card} [data-role='latest-failure-message'].line-clamp-2")

    assert has_element?(
             view,
             "#{card} [data-role='failed-worker-dialog']",
             "Run discarded"
           )

    rendered = render(view)
    refute rendered =~ "Oban.PerformError"
    refute rendered =~ "TokenRefreshWorker failed with :discard"
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
