defmodule CodexPooler.Jobs.HealthPolicyTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Jobs.HealthPolicy

  alias CodexPooler.Jobs.{
    CatalogSyncWorker,
    TokenRefreshWorker
  }

  @now ~U[2026-06-02 12:00:00Z]

  describe "classify/2" do
    test "classifies terminal and failure states" do
      assert HealthPolicy.classify(job("discarded"), now: @now) == :active_failure
      assert HealthPolicy.classify(job("retryable"), now: @now) == :retry_pressure
      assert HealthPolicy.classify(job("cancelled"), now: @now) == :cancelled
      assert HealthPolicy.classify(job("completed"), now: @now) == :healthy_context
    end

    test "classifies known executing jobs as stuck only after their worker timeout" do
      under_timeout =
        job("executing",
          worker: CatalogSyncWorker,
          attempted_at: DateTime.add(@now, -14, :minute),
          inserted_at: DateTime.add(@now, -30, :minute)
        )

      over_timeout =
        job("executing",
          worker: CatalogSyncWorker,
          attempted_at: DateTime.add(@now, -16, :minute),
          inserted_at: DateTime.add(@now, -30, :minute)
        )

      assert HealthPolicy.classify(under_timeout, now: @now) == :executing
      assert HealthPolicy.classify(over_timeout, now: @now) == :stuck_executing
    end

    test "keeps unknown historical executing workers in plain executing state" do
      stale_unknown_worker =
        job("executing",
          worker: "CodexPooler.Jobs.LegacyUnknownWorker",
          attempted_at: DateTime.add(@now, -2, :hour)
        )

      assert HealthPolicy.classify(stale_unknown_worker, now: @now) == :executing
    end

    test "uses scheduled_at before inserted_at for backlog pressure" do
      overdue_available =
        job("available",
          inserted_at: DateTime.add(@now, -6, :minute),
          scheduled_at: nil
        )

      overdue_scheduled =
        job("scheduled",
          inserted_at: DateTime.add(@now, -1, :hour),
          scheduled_at: DateTime.add(@now, -6, :minute)
        )

      future_scheduled =
        job("scheduled",
          inserted_at: DateTime.add(@now, -1, :hour),
          scheduled_at: DateTime.add(@now, 1, :minute)
        )

      assert HealthPolicy.classify(overdue_available, now: @now) == :backlog_pressure
      assert HealthPolicy.classify(overdue_scheduled, now: @now) == :backlog_pressure
      assert HealthPolicy.classify(future_scheduled, now: @now) == :scheduled
    end

    test "falls back safely for held or unknown states" do
      assert HealthPolicy.classify(job("suspended"), now: @now) == :suspended
      assert HealthPolicy.classify(job("unknown-new-state"), now: @now) == :unknown_state
    end
  end

  describe "put_attention/2" do
    test "adds the classification without exposing raw job payloads" do
      classified =
        "retryable"
        |> job(worker: TokenRefreshWorker)
        |> HealthPolicy.put_attention(now: @now)

      assert classified.attention_state == :retry_pressure
      refute Map.has_key?(classified, :args)
      refute Map.has_key?(classified, :meta)
    end
  end

  defp job(state, attrs \\ []) do
    %{
      state: state,
      worker: attrs |> Keyword.get(:worker, CatalogSyncWorker) |> worker_name(),
      inserted_at: Keyword.get(attrs, :inserted_at, DateTime.add(@now, -1, :minute)),
      scheduled_at: Keyword.get(attrs, :scheduled_at, DateTime.add(@now, -1, :minute)),
      attempted_at: Keyword.get(attrs, :attempted_at)
    }
  end

  defp worker_name(worker) when is_atom(worker) do
    worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  end

  defp worker_name(worker) when is_binary(worker), do: worker
end
