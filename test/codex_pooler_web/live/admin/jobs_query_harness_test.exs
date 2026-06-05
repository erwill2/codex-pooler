defmodule CodexPoolerWeb.Admin.JobsQueryHarnessTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodexPooler.JobsQueryBudgetHelper
  alias CodexPooler.Repo

  @evidence_path ".omo/evidence/task-1-jobs-query-harness.txt"
  @shared_helper_note "shared_helper_module=CodexPooler.JobsQueryBudgetHelper"
  @shared_helper_file_note "shared_helper_file=test/support/jobs_query_budget_helper.ex"

  setup :register_and_log_in_user

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  @tag :harness_smoke
  test "captures end-to-end initial load query telemetry for /admin/jobs", %{conn: conn} do
    entries = collect_harness_entries!(conn)
    JobsQueryBudgetHelper.write_report!(@evidence_path, entries)

    smoke_entry = Enum.find(entries, &(&1.flow_name == "harness_smoke"))

    assert smoke_entry
    html = smoke_entry.rendered_html
    events = smoke_entry.events

    assert html =~ ~s(id="admin-jobs-page")
    assert html =~ ~s(id="admin-jobs-explorer")
    assert length(events) > 0
    assert map_size(JobsQueryBudgetHelper.summarize_by_source_and_command(events)) > 0

    written = File.read!(@evidence_path)
    assert written =~ "flow=harness_smoke"
    assert written =~ "flow=harness_invalid_flow"
    assert written =~ "fixture_setup_excluded=true"
    assert written =~ @shared_helper_note
    assert written =~ "breakdown:"
  end

  @tag :harness_invalid_flow
  test "captures invalid jobs filter flow without sensitive leakage", %{conn: conn} do
    entries = collect_harness_entries!(conn)
    JobsQueryBudgetHelper.write_report!(@evidence_path, entries)

    invalid_entry = Enum.find(entries, &(&1.flow_name == "harness_invalid_flow"))

    assert invalid_entry
    html = invalid_entry.rendered_html
    events = invalid_entry.events

    assert html =~ ~s(id="job-filter-form")
    assert html =~ "Completed jobs require show_completed=true"
    assert html =~ "Job id must be a positive integer"
    assert length(events) > 0

    written = File.read!(@evidence_path)
    assert written =~ "flow=harness_invalid_flow"
    refute written =~ "authorization"
    refute written =~ "Bearer "
    refute written =~ "auth.json"
  end

  defp collect_harness_entries!(conn) do
    [
      harness_smoke_entry!(conn),
      harness_invalid_flow_entry!(conn)
    ]
  end

  defp harness_smoke_entry!(conn) do
    measurement =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        live(conn, ~p"/admin/jobs")
      end)

    {{:ok, view, html}, events} = measurement
    stop_view!(view)

    %{
      flow_name: "harness_smoke",
      events: events,
      rendered_html: html,
      metrics: %{html_bytes: byte_size(html)},
      notes: [
        "fixture_setup_excluded=true",
        "path=/admin/jobs",
        @shared_helper_note,
        @shared_helper_file_note
      ]
    }
  end

  defp harness_invalid_flow_entry!(conn) do
    path = ~p"/admin/jobs?state=completed&job_id=not-an-id"

    measurement =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        live(conn, path)
      end)

    {{:ok, view, html}, events} = measurement
    stop_view!(view)

    %{
      flow_name: "harness_invalid_flow",
      events: events,
      rendered_html: html,
      metrics: %{html_bytes: byte_size(html), warning_count: 2},
      notes: [
        "fixture_setup_excluded=true",
        "path=#{path}",
        @shared_helper_note,
        @shared_helper_file_note
      ]
    }
  end

  defp stop_view!(view), do: _result = GenServer.stop(view.pid, :normal, 1_000)
end
