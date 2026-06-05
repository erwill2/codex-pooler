defmodule CodexPoolerWeb.Admin.JobsQueryWorkerCardTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Jobs.ReadModel
  alias CodexPooler.Jobs.Schedule
  alias CodexPooler.JobsQueryBudgetDatasets
  alias CodexPooler.JobsQueryBudgetHelper

  @evidence_path ".omo/evidence/task-6-admin-jobs-worker-batch-regression.txt"
  @max_worker_card_oban_jobs_selects 6

  setup do
    JobsQueryBudgetDatasets.clear_jobs!()
    :ok
  end

  @tag :worker_card_batch_regression
  test "enforces constant all-groups worker-card cost on the heavy dataset" do
    entries = collect_worker_card_entries!()
    write_worker_card_report!(entries)

    heavy_all_groups = entry!(entries, "worker_card_batch.all_groups.heavy")
    heavy_one_group = entry!(entries, "worker_card_batch.one_group.heavy")

    assert heavy_all_groups.metrics.oban_jobs_selects <= @max_worker_card_oban_jobs_selects
    assert heavy_all_groups.metrics.worker_group_count == length(Schedule.worker_groups())
    assert heavy_all_groups.metrics.worker_group_count > 1

    assert heavy_all_groups.metrics.oban_jobs_selects <
             heavy_one_group.metrics.oban_jobs_selects *
               heavy_all_groups.metrics.worker_group_count
  end

  @tag :worker_card_empty_batch_regression
  test "enforces constant all-groups worker-card cost on the empty dataset" do
    entries = collect_worker_card_entries!()
    write_worker_card_report!(entries)

    empty_all_groups = entry!(entries, "worker_card_batch.all_groups.empty")
    empty_one_group = entry!(entries, "worker_card_batch.one_group.empty")

    assert empty_all_groups.metrics.oban_jobs_selects <= @max_worker_card_oban_jobs_selects
    assert empty_all_groups.metrics.worker_group_count == length(Schedule.worker_groups())
    assert empty_all_groups.metrics.worker_group_count > 1

    assert empty_all_groups.metrics.oban_jobs_selects <
             empty_one_group.metrics.oban_jobs_selects *
               empty_all_groups.metrics.worker_group_count
  end

  defp collect_worker_card_entries! do
    heavy_dataset = JobsQueryBudgetDatasets.heavy_dataset!()
    heavy_entries = dataset_entries!("heavy", heavy_dataset)

    JobsQueryBudgetDatasets.clear_jobs!()

    empty_dataset = JobsQueryBudgetDatasets.empty_dataset!()
    empty_entries = dataset_entries!("empty", empty_dataset)

    heavy_entries ++ empty_entries
  end

  defp dataset_entries!(suffix, dataset) do
    worker_groups = Schedule.worker_groups()
    first_group = List.first(worker_groups)

    [
      all_groups_entry!(worker_groups, suffix, dataset),
      one_group_entry!(first_group, suffix, dataset)
    ]
  end

  defp all_groups_entry!(worker_groups, suffix, dataset) do
    {summaries_by_group, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        ReadModel.worker_job_summaries_by_group(:system, worker_groups)
      end)

    assert is_map(summaries_by_group)
    assert map_size(summaries_by_group) == length(worker_groups)

    %{
      flow_name: "worker_card_batch.all_groups.#{suffix}",
      events: events,
      metrics:
        worker_card_metrics(events, summaries_by_group, %{
          dataset_jobs: length(dataset.jobs),
          worker_group_count: length(worker_groups)
        }),
      notes: [
        "dataset=#{dataset.name}",
        "path=grouped_worker_summary",
        "budget=oban_jobs_selects<=#{@max_worker_card_oban_jobs_selects}",
        "scale_check=all_groups_not_one_group_times_group_count"
      ]
    }
  end

  defp one_group_entry!(group, suffix, dataset) do
    {summary, events} =
      JobsQueryBudgetHelper.capture_repo_queries(fn ->
        ReadModel.worker_job_summary(:system, group.workers)
      end)

    assert is_map(summary)

    %{
      flow_name: "worker_card_batch.one_group.#{suffix}",
      events: events,
      metrics:
        worker_card_metrics(events, %{group.key => summary}, %{
          dataset_jobs: length(dataset.jobs),
          worker_group_count: 1
        }),
      notes: [
        "dataset=#{dataset.name}",
        "group_key=#{group.key}",
        "workers=#{Enum.join(group.workers, ",")}",
        "path=single_group_compatibility"
      ]
    }
  end

  defp entry!(entries, flow_name),
    do: Enum.find(entries, &(&1.flow_name == flow_name)) || flunk("missing #{flow_name}")

  defp write_worker_card_report!(entries) do
    JobsQueryBudgetHelper.write_report!(@evidence_path, entries)

    heavy_all_groups = entry!(entries, "worker_card_batch.all_groups.heavy")
    heavy_one_group = entry!(entries, "worker_card_batch.one_group.heavy")
    empty_all_groups = entry!(entries, "worker_card_batch.all_groups.empty")
    empty_one_group = entry!(entries, "worker_card_batch.one_group.empty")

    summary_lines = [
      "",
      "summary_queries=latest,latest_success,latest_failure,pending,active,unresolved_failures",
      "heavy_total_oban_jobs_selects=#{heavy_all_groups.metrics.oban_jobs_selects}",
      "empty_total_oban_jobs_selects=#{empty_all_groups.metrics.oban_jobs_selects}",
      "heavy_one_group_oban_jobs_selects=#{heavy_one_group.metrics.oban_jobs_selects}",
      "empty_one_group_oban_jobs_selects=#{empty_one_group.metrics.oban_jobs_selects}",
      "worker_group_count=#{heavy_all_groups.metrics.worker_group_count}",
      "constant_cost_budget=all configured groups stay within #{@max_worker_card_oban_jobs_selects} oban_jobs SELECTs",
      "scale_check=all_groups cost no longer scales as one_group * worker_group_count"
    ]

    File.write!(
      Path.expand(@evidence_path, File.cwd!()),
      "
" <> Enum.join(summary_lines, "
") <> "
",
      [:append]
    )
  end

  defp worker_card_metrics(events, summaries_by_group, extra_metrics) do
    summary_values = Map.values(summaries_by_group)

    Map.merge(
      %{
        total: length(events),
        oban_jobs_queries: oban_jobs_query_count(events),
        oban_jobs_selects: oban_jobs_select_count(events),
        unresolved_failures:
          Enum.reduce(summary_values, 0, &(&2 + length(&1.unresolved_failures || []))),
        active_jobs: Enum.reduce(summary_values, 0, &(&2 + length(&1.active || [])))
      },
      extra_metrics
    )
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
end
