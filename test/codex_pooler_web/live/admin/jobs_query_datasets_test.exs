defmodule CodexPoolerWeb.Admin.JobsQueryDatasetsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.JobsQueryBudgetDatasets

  @evidence_path ".omo/evidence/task-2-jobs-dataset-matrix.txt"

  setup do
    JobsQueryBudgetDatasets.clear_jobs!()
    :ok
  end

  @tag :heavy_dataset
  test "heavy dataset covers every configured worker group and mixed states" do
    dataset = JobsQueryBudgetDatasets.heavy_dataset!()
    summary = JobsQueryBudgetDatasets.dataset_summary(dataset)

    assert summary.job_count >= 32
    assert summary.worker_group_count == 7
    assert Enum.sort(summary.present_worker_groups) == Enum.sort(dataset.worker_group_keys)
    assert summary.has_failed_jobs?
    assert summary.has_scheduled_jobs?
    assert summary.has_completed_jobs?

    write_canonical_dataset_matrix!()
  end

  @tag :failed_sanitized_dataset
  test "failed sanitized dataset keeps secrets only in source rows, not evidence" do
    dataset = JobsQueryBudgetDatasets.failed_sanitized_dataset!()
    summary = JobsQueryBudgetDatasets.dataset_summary(dataset)

    assert summary.has_failed_jobs?
    assert summary.has_targeted_jobs?
    assert Enum.any?(dataset.jobs, &(&1.state == "discarded"))

    write_canonical_dataset_matrix!()

    written = File.read!(@evidence_path)
    assert written =~ "dataset=failed_sanitized"
    refute written =~ dataset.redaction_values.token
    refute written =~ dataset.redaction_values.prompt
    refute written =~ dataset.redaction_values.cookie
    refute written =~ dataset.redaction_values.error
  end

  test "dataset helpers provide empty and small realistic baselines" do
    empty_dataset = JobsQueryBudgetDatasets.empty_dataset!()
    small_dataset = JobsQueryBudgetDatasets.small_realistic_dataset!()

    empty_summary = JobsQueryBudgetDatasets.dataset_summary(empty_dataset)
    small_summary = JobsQueryBudgetDatasets.dataset_summary(small_dataset)

    assert empty_summary.job_count == 0
    assert small_summary.job_count == 5
    assert small_summary.has_completed_jobs?
    assert small_summary.has_scheduled_jobs?
    assert small_summary.has_targeted_jobs?

    write_canonical_dataset_matrix!()
  end

  defp write_dataset_matrix!(summaries) do
    expanded_path = Path.expand(@evidence_path, File.cwd!())
    File.mkdir_p!(Path.dirname(expanded_path))

    contents =
      summaries
      |> Enum.map(fn summary ->
        [
          "dataset=#{summary.name}",
          "job_count=#{summary.job_count}",
          "worker_group_count=#{summary.worker_group_count}",
          "present_worker_groups=#{Enum.join(summary.present_worker_groups, ",")}",
          "flows=#{dataset_flows(summary.name)}",
          "has_failed_jobs=#{summary.has_failed_jobs?}",
          "has_scheduled_jobs=#{summary.has_scheduled_jobs?}",
          "has_completed_jobs=#{summary.has_completed_jobs?}",
          "has_targeted_jobs=#{summary.has_targeted_jobs?}"
        ]
        |> Enum.join(" ")
      end)
      |> Enum.join("\n")

    File.write!(expanded_path, contents)
  end

  defp write_canonical_dataset_matrix! do
    summaries =
      [:empty, :small_realistic, :heavy, :failed_sanitized]
      |> Enum.map(&canonical_summary!/1)

    write_dataset_matrix!(summaries)
  end

  defp canonical_summary!(:empty) do
    JobsQueryBudgetDatasets.clear_jobs!()

    JobsQueryBudgetDatasets.empty_dataset!()
    |> JobsQueryBudgetDatasets.dataset_summary()
  end

  defp canonical_summary!(:small_realistic) do
    JobsQueryBudgetDatasets.small_realistic_dataset!()
    |> JobsQueryBudgetDatasets.dataset_summary()
  end

  defp canonical_summary!(:heavy) do
    JobsQueryBudgetDatasets.heavy_dataset!()
    |> JobsQueryBudgetDatasets.dataset_summary()
  end

  defp canonical_summary!(:failed_sanitized) do
    JobsQueryBudgetDatasets.failed_sanitized_dataset!()
    |> JobsQueryBudgetDatasets.dataset_summary()
  end

  defp dataset_flows("empty"), do: "harness_smoke,owner_initial_load,non_owner_load"

  defp dataset_flows("small_realistic"),
    do: "owner_initial_projection,owner_filter,owner_selected_job,owner_pagination"

  defp dataset_flows("heavy"),
    do: "worker_card_fanout,standard_filter,attention_filter,pubsub_refresh,fallback_refresh"

  defp dataset_flows("failed_sanitized"),
    do: "failed_sanitized_dataset,overview_dead_work_redaction_checks"
end
