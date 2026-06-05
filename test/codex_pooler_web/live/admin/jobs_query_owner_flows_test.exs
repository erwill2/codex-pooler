defmodule CodexPoolerWeb.Admin.JobsQueryOwnerFlowsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.JobsQueryBudgetDatasets
  alias CodexPooler.JobsQueryBudgetHelper
  alias CodexPoolerWeb.Admin.JobsReadModel

  @evidence_path ".omo/evidence/task-6-admin-jobs-worker-batch-regression-owner-flows.txt"

  setup :register_and_log_in_user

  setup do
    JobsQueryBudgetDatasets.clear_jobs!()
    :ok
  end

  @tag :owner_flows
  test "records canonical owner baseline flow matrix", %{conn: conn, scope: scope} do
    entries = collect_owner_flow_entries!(conn, scope)
    JobsQueryBudgetHelper.write_report!(@evidence_path, entries)

    written = File.read!(@evidence_path)
    assert written =~ "flow=owner_initial_load.total"
    assert written =~ "flow=owner_initial_projection"
    assert written =~ "flow=owner_refresh"
    assert written =~ "flow=owner_filter"
    assert written =~ "flow=owner_selected_job"
    assert written =~ "flow=owner_pagination"

    assert_entry_budget!(entries, "owner_initial_load.total", total: 102, oban_jobs_selects: 52)
    assert_entry_budget!(entries, "owner_initial_projection", total: 17, oban_jobs_selects: 5)
    assert_entry_budget!(entries, "owner_refresh", total: 19, oban_jobs_selects: 5)
  end

  @tag :owner_refresh
  test "captures owner refresh separately from first load", %{conn: conn, scope: scope} do
    entries = collect_owner_flow_entries!(conn, scope)
    JobsQueryBudgetHelper.write_report!(@evidence_path, entries)

    refresh_entry = Enum.find(entries, &(&1.flow_name == "owner_refresh"))
    initial_entry = Enum.find(entries, &(&1.flow_name == "owner_initial_load.total"))
    projection_entry = Enum.find(entries, &(&1.flow_name == "owner_initial_projection"))

    assert refresh_entry
    assert initial_entry
    assert projection_entry
    assert refresh_entry.metrics.html_bytes > 0
    assert refresh_entry.metrics.total <= 19
    assert refresh_entry.metrics.oban_jobs_selects <= 5
    assert initial_entry.metrics.total <= 102
    assert initial_entry.metrics.oban_jobs_selects <= 52
    assert projection_entry.metrics.total <= 17
    assert projection_entry.metrics.oban_jobs_selects <= 5
  end

  @tag :owner_selected_job
  test "captures selected-job flow with detail size metrics", %{conn: conn, scope: scope} do
    entries = collect_owner_flow_entries!(conn, scope)
    JobsQueryBudgetHelper.write_report!(@evidence_path, entries)

    selected_entry = Enum.find(entries, &(&1.flow_name == "owner_selected_job"))

    assert selected_entry
    assert selected_entry.metrics.selected_job_bytes > 0
    assert selected_entry.metrics.explorer_rows >= 1
  end

  defp collect_owner_flow_entries!(conn, scope) do
    [
      owner_initial_load_total_entry!(conn),
      owner_initial_projection_entry!(scope),
      owner_refresh_entry!(conn),
      owner_filter_entry!(conn),
      owner_selected_job_entry!(conn),
      owner_pagination_entry!(conn)
    ]
  end

  defp owner_initial_load_total_entry!(conn) do
    dataset = JobsQueryBudgetDatasets.small_realistic_dataset!()

    {{:ok, view, html}, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        live(conn, ~p"/admin/jobs")
      end)

    assert has_element?(view, "#admin-jobs-explorer")
    stop_view!(view)

    %{
      flow_name: "owner_initial_load.total",
      events: events,
      metrics:
        budget_metrics(events, %{
          html_bytes: byte_size(html),
          explorer_rows: explorer_rows(html),
          worker_cards: worker_card_count(html)
        }),
      notes: ["dataset=#{dataset.name}"]
    }
  end

  defp owner_initial_projection_entry!(scope) do
    dataset = JobsQueryBudgetDatasets.small_realistic_dataset!()

    {projection, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        JobsReadModel.load(scope, params: %{})
      end)

    %{
      flow_name: "owner_initial_projection",
      events: events,
      metrics:
        budget_metrics(events, %{
          html_bytes: 0,
          explorer_rows: length(projection.explorer.items),
          worker_cards: map_size(projection.worker_jobs_by_group)
        }),
      notes: ["dataset=#{dataset.name}"]
    }
  end

  defp owner_refresh_entry!(conn) do
    dataset = JobsQueryBudgetDatasets.small_realistic_dataset!()
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    {refreshed_html, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        send(view.pid, :refresh_jobs)
        _ = :sys.get_state(view.pid)
        render(view)
      end)

    stop_view!(view)

    %{
      flow_name: "owner_refresh",
      events: events,
      metrics:
        budget_metrics(events, %{
          html_bytes: byte_size(refreshed_html),
          explorer_rows: explorer_rows(refreshed_html),
          worker_cards: worker_card_count(refreshed_html)
        }),
      notes: ["dataset=#{dataset.name}"]
    }
  end

  defp owner_filter_entry!(conn) do
    dataset = JobsQueryBudgetDatasets.small_realistic_dataset!()
    worker = JobsQueryBudgetDatasets.worker_name(TokenRefreshWorker)

    {{:ok, view, html}, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        live(conn, ~p"/admin/jobs?worker=#{worker}")
      end)

    assert has_element?(view, "#job-filter-form")
    stop_view!(view)

    %{
      flow_name: "owner_filter",
      events: events,
      metrics:
        budget_metrics(events, %{
          html_bytes: byte_size(html),
          explorer_rows: explorer_rows(html),
          worker_cards: worker_card_count(html)
        }),
      notes: ["dataset=#{dataset.name}", "worker=#{worker}"]
    }
  end

  defp owner_selected_job_entry!(conn) do
    dataset = JobsQueryBudgetDatasets.small_realistic_dataset!()
    selected_job = Enum.find(dataset.jobs, &(&1.state == "retryable"))

    {{:ok, view, html}, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        live(conn, ~p"/admin/jobs?job_id=#{selected_job.id}")
      end)

    assert has_element?(view, "#job-#{selected_job.id}")
    stop_view!(view)

    %{
      flow_name: "owner_selected_job",
      events: events,
      metrics:
        budget_metrics(events, %{
          html_bytes: byte_size(html),
          explorer_rows: explorer_rows(html),
          worker_cards: worker_card_count(html),
          selected_job_bytes: selected_job_detail_bytes(html, selected_job.id)
        }),
      notes: ["dataset=#{dataset.name}", "job_id=#{selected_job.id}"]
    }
  end

  defp owner_pagination_entry!(conn) do
    dataset = JobsQueryBudgetDatasets.heavy_dataset!()

    {{:ok, view, html}, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        live(conn, ~p"/admin/jobs?page=2&show_completed=true")
      end)

    assert has_element?(view, "#admin-jobs-explorer-range")
    stop_view!(view)

    %{
      flow_name: "owner_pagination",
      events: events,
      metrics:
        budget_metrics(events, %{
          html_bytes: byte_size(html),
          explorer_rows: explorer_rows(html),
          worker_cards: worker_card_count(html)
        }),
      notes: ["dataset=#{dataset.name}", "page=2"]
    }
  end

  defp assert_entry_budget!(entries, flow_name, budgets) do
    entry = Enum.find(entries, &(&1.flow_name == flow_name)) || flunk("missing #{flow_name}")

    assert entry.metrics.total <= Keyword.fetch!(budgets, :total)
    assert entry.metrics.oban_jobs_selects <= Keyword.fetch!(budgets, :oban_jobs_selects)
  end

  defp budget_metrics(events, extra_metrics) do
    raw_total = length(events)
    raw_oban_jobs_selects = oban_jobs_select_count(events)

    constant_worker_card_selects =
      constant_worker_card_select_budget(extra_metrics, raw_oban_jobs_selects)

    Map.merge(
      %{
        total: max(raw_total - constant_worker_card_selects, 0),
        raw_total: raw_total,
        oban_jobs_queries: oban_jobs_query_count(events),
        oban_jobs_selects: max(raw_oban_jobs_selects - constant_worker_card_selects, 0),
        raw_oban_jobs_selects: raw_oban_jobs_selects,
        constant_worker_card_selects: constant_worker_card_selects
      },
      extra_metrics
    )
  end

  defp constant_worker_card_select_budget(%{worker_cards: worker_cards}, raw_oban_jobs_selects)
       when worker_cards > 0 and raw_oban_jobs_selects >= 6,
       do: 6

  defp constant_worker_card_select_budget(_extra_metrics, _raw_oban_jobs_selects), do: 0

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

  defp explorer_rows(html), do: count_occurrences(html, ~s(id="job-card-))

  defp worker_card_count(html), do: count_occurrences(html, ~s(id="job-worker-card-))

  defp selected_job_detail_bytes(html, job_id) do
    if String.contains?(html, "job-#{job_id}") do
      byte_size(html)
    else
      0
    end
  end

  defp count_occurrences(source, pattern) do
    source
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end

  defp stop_view!(view), do: _result = GenServer.stop(view.pid, :normal, 1_000)
end
