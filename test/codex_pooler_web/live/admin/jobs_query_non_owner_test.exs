defmodule CodexPoolerWeb.Admin.JobsQueryNonOwnerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.JobsQueryBudgetDatasets
  alias CodexPooler.JobsQueryBudgetHelper

  @evidence_path ".omo/evidence/task-6-admin-jobs-worker-batch-regression-non-owner.txt"

  setup :register_and_log_in_user

  setup do
    JobsQueryBudgetDatasets.clear_jobs!()
    :ok
  end

  @tag :non_owner_load
  test "non-owner load stays safe and does not query global jobs", %{conn: conn, scope: scope} do
    entries = collect_non_owner_entries!(conn, scope)
    JobsQueryBudgetHelper.write_report!(@evidence_path, entries)

    load_entry = Enum.find(entries, &(&1.flow_name == "non_owner_load"))

    assert load_entry
    assert load_entry.metrics.oban_jobs_queries == 0
    assert load_entry.metrics.oban_jobs_selects == 0
  end

  @tag :non_owner_invalid_params
  test "non-owner invalid params still avoid global jobs work", %{conn: conn, scope: scope} do
    entries = collect_non_owner_entries!(conn, scope)
    JobsQueryBudgetHelper.write_report!(@evidence_path, entries)

    invalid_entry = Enum.find(entries, &(&1.flow_name == "non_owner_invalid_params"))

    assert invalid_entry
    assert invalid_entry.metrics.oban_jobs_queries == 0
    assert invalid_entry.metrics.oban_jobs_selects == 0
  end

  defp collect_non_owner_entries!(conn, owner_scope) do
    dataset = JobsQueryBudgetDatasets.small_realistic_dataset!()
    [first_job | _rest] = dataset.jobs
    admin_conn = non_owner_conn!(conn, owner_scope)
    worker = JobsQueryBudgetDatasets.worker_name(TokenRefreshWorker)

    [
      non_owner_load_entry!(admin_conn, first_job.id),
      non_owner_invalid_params_entry!(admin_conn, first_job.id, worker)
    ]
  end

  defp non_owner_load_entry!(admin_conn, hidden_job_id) do
    {{:ok, view, html}, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        live(admin_conn, ~p"/admin/jobs")
      end)

    assert has_element?(view, "#admin-jobs-owner-denied")
    refute has_element?(view, "#job-#{hidden_job_id}")
    stop_view!(view)

    %{
      flow_name: "non_owner_load",
      events: events,
      metrics: %{
        html_bytes: byte_size(html),
        explorer_rows: 0,
        worker_cards: 0,
        oban_jobs_queries: oban_jobs_query_count(events),
        oban_jobs_selects: oban_jobs_select_count(events)
      },
      notes: ["unexpected_domain_query_work=#{oban_jobs_query_count(events) > 0}"]
    }
  end

  defp non_owner_invalid_params_entry!(admin_conn, hidden_job_id, worker) do
    path = ~p"/admin/jobs?job_id=#{hidden_job_id}&worker=#{worker}&page=0"

    {{:ok, view, html}, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        live(admin_conn, path)
      end)

    assert has_element?(view, "#admin-jobs-owner-denied")
    refute has_element?(view, "#job-#{hidden_job_id}")
    stop_view!(view)

    %{
      flow_name: "non_owner_invalid_params",
      events: events,
      metrics: %{
        html_bytes: byte_size(html),
        explorer_rows: 0,
        worker_cards: 0,
        oban_jobs_queries: oban_jobs_query_count(events),
        oban_jobs_selects: oban_jobs_select_count(events)
      },
      notes: [
        "unexpected_domain_query_work=#{oban_jobs_query_count(events) > 0}",
        "params_ignored_for_non_owner=true"
      ]
    }
  end

  defp non_owner_conn!(conn, owner_scope) do
    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "password_change_required" => "false"
      })

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    log_in_user(conn, admin, token)
  end

  defp oban_jobs_query_count(events) do
    events
    |> JobsQueryBudgetHelper.summarize_by_source_and_command()
    |> Enum.reduce(0, fn
      {{"oban_jobs", _command}, count}, total -> total + count
      {_key, _count}, total -> total
    end)
  end

  defp oban_jobs_select_count(events) do
    events
    |> JobsQueryBudgetHelper.summarize_by_source_and_command()
    |> Enum.reduce(0, fn
      {{"oban_jobs", "SELECT"}, count}, total -> total + count
      {_key, _count}, total -> total
    end)
  end

  defp stop_view!(view), do: _result = GenServer.stop(view.pid, :normal, 1_000)
end
