defmodule CodexPoolerWeb.Admin.JobsQueryFilterRefreshTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodexPooler.Events
  alias CodexPooler.JobsQueryBudgetDatasets
  alias CodexPooler.JobsQueryBudgetHelper

  @evidence_path ".omo/evidence/task-7-jobs-filter-refresh-cost.txt"

  setup :register_and_log_in_user

  setup do
    JobsQueryBudgetDatasets.clear_jobs!()
    :ok
  end

  @tag :attention_filter
  test "captures local standard and attention filter baselines", %{conn: conn} do
    entries = collect_filter_refresh_entries!(conn)
    JobsQueryBudgetHelper.write_report!(@evidence_path, entries)

    standard_filter = Enum.find(entries, &(&1.flow_name == "standard_filter"))
    attention_filter = Enum.find(entries, &(&1.flow_name == "attention_filter"))

    assert standard_filter
    assert attention_filter
    assert attention_filter.metrics.query_delta_from_standard_filter >= 0
  end

  @tag :fallback_refresh
  test "captures pubsub and fallback refresh reload cost", %{conn: conn} do
    entries = collect_filter_refresh_entries!(conn)
    JobsQueryBudgetHelper.write_report!(@evidence_path, entries)

    pubsub_refresh = Enum.find(entries, &(&1.flow_name == "pubsub_refresh"))
    fallback_refresh = Enum.find(entries, &(&1.flow_name == "fallback_refresh"))

    assert pubsub_refresh
    assert fallback_refresh
    assert pubsub_refresh.metrics.full_projection_reload
    assert fallback_refresh.metrics.full_projection_reload
  end

  defp collect_filter_refresh_entries!(conn) do
    dataset = JobsQueryBudgetDatasets.heavy_dataset!()
    standard_filter = standard_filter_entry!(conn, dataset)
    attention_filter = attention_filter_entry!(conn, dataset, standard_filter.metrics.queries)
    normal_refresh = normal_refresh_entry!(conn, dataset)
    pubsub_refresh = pubsub_refresh_entry!(conn, dataset, normal_refresh.metrics.queries)
    fallback_refresh = fallback_refresh_entry!(conn, dataset, normal_refresh.metrics.queries)

    [standard_filter, attention_filter, normal_refresh, pubsub_refresh, fallback_refresh]
  end

  defp standard_filter_entry!(conn, dataset) do
    {{:ok, view, html}, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        live(conn, ~p"/admin/jobs?state=retryable")
      end)

    assert has_element?(view, "#filters_state[value='retryable']")
    stop_view!(view)

    %{
      flow_name: "standard_filter",
      events: events,
      metrics: %{
        queries: length(events),
        html_bytes: byte_size(html),
        explorer_rows: explorer_rows(html),
        worker_cards: worker_card_count(html)
      },
      notes: ["dataset=#{dataset.name}", "comparison=state_retryable"]
    }
  end

  defp attention_filter_entry!(conn, dataset, standard_filter_queries) do
    {{:ok, view, html}, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        live(conn, ~p"/admin/jobs?attention=retry_pressure")
      end)

    assert has_element?(view, "#filters_attention[value='retry_pressure']")
    stop_view!(view)

    %{
      flow_name: "attention_filter",
      events: events,
      metrics: %{
        queries: length(events),
        html_bytes: byte_size(html),
        explorer_rows: explorer_rows(html),
        worker_cards: worker_card_count(html),
        query_delta_from_standard_filter: length(events) - standard_filter_queries
      },
      notes: ["dataset=#{dataset.name}", "comparison_baseline=standard_filter"]
    }
  end

  defp normal_refresh_entry!(conn, dataset) do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    {refreshed_html, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        send(view.pid, :refresh_jobs)
        _ = :sys.get_state(view.pid)
        render(view)
      end)

    stop_view!(view)

    %{
      flow_name: "normal_refresh",
      events: events,
      metrics: %{
        queries: length(events),
        html_bytes: byte_size(refreshed_html),
        explorer_rows: explorer_rows(refreshed_html),
        worker_cards: worker_card_count(refreshed_html),
        full_projection_reload: true
      },
      notes: [
        "dataset=#{dataset.name}",
        "reload_path=refresh_jobs->load_jobs_page->JobsReadModel.load"
      ]
    }
  end

  defp pubsub_refresh_entry!(conn, dataset, normal_refresh_queries) do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    pool = List.first(dataset.pools)
    job = List.first(dataset.jobs)

    assert {:ok, _event} =
             Events.broadcast_job_status(pool.id, "job_status_updated", %{
               id: Integer.to_string(job.id),
               status: job.state
             })

    state = :sys.get_state(view.pid)
    assert is_reference(state.socket.assigns.jobs_reload_timer)

    {refreshed_html, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        send(view.pid, :refresh_jobs)
        _ = :sys.get_state(view.pid)
        render(view)
      end)

    stop_view!(view)

    %{
      flow_name: "pubsub_refresh",
      events: events,
      metrics: %{
        queries: length(events),
        html_bytes: byte_size(refreshed_html),
        explorer_rows: explorer_rows(refreshed_html),
        worker_cards: worker_card_count(refreshed_html),
        full_projection_reload: true,
        query_delta_from_normal_refresh: length(events) - normal_refresh_queries
      },
      notes: ["dataset=#{dataset.name}", "comparison_baseline=normal_refresh"]
    }
  end

  defp fallback_refresh_entry!(conn, dataset, normal_refresh_queries) do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    {refreshed_html, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        send(view.pid, :fallback_refresh_jobs)
        _ = :sys.get_state(view.pid)
        render(view)
      end)

    stop_view!(view)

    %{
      flow_name: "fallback_refresh",
      events: events,
      metrics: %{
        queries: length(events),
        html_bytes: byte_size(refreshed_html),
        explorer_rows: explorer_rows(refreshed_html),
        worker_cards: worker_card_count(refreshed_html),
        full_projection_reload: true,
        query_delta_from_normal_refresh: length(events) - normal_refresh_queries
      },
      notes: ["dataset=#{dataset.name}", "comparison_baseline=normal_refresh"]
    }
  end

  defp explorer_rows(html), do: count_occurrences(html, ~s(id="job-card-))

  defp worker_card_count(html), do: count_occurrences(html, ~s(id="job-worker-card-))

  defp count_occurrences(source, pattern) do
    source
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end

  defp stop_view!(view), do: _result = GenServer.stop(view.pid, :normal, 1_000)
end
