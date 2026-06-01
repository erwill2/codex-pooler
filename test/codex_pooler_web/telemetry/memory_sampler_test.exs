defmodule CodexPoolerWeb.Telemetry.MemorySamplerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexPoolerWeb.Telemetry.MemorySampler

  test "logs a sanitized top-process snapshot when memory crosses the configured threshold" do
    name = :"memory-sampler-test-#{System.unique_integer([:positive])}"
    attach_id = {__MODULE__, name}

    {:ok, pid} =
      start_supervised(
        {MemorySampler,
         enabled?: true,
         name: name,
         attach_id: attach_id,
         limit_bytes: 100,
         threshold_ratio: 0.5,
         min_interval_ms: 0,
         top_processes: 1,
         cgroup_usage_reader: fn -> 80 end}
      )

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:vm, :memory],
          %{total: 60, binary: 10, processes: 20, processes_used: 15, ets: 5},
          %{}
        )

        :sys.get_state(pid)
      end)

    assert log =~ "memory sampler threshold exceeded"
    assert log =~ "beam_total_bytes=60"
    assert log =~ "cgroup_usage_bytes=80"
    assert log =~ "limit_bytes=100"
    assert log =~ "top_processes="
    assert log =~ "top_message_queues="
  end

  test "detaches the VM memory handler on supervised shutdown" do
    name = :"memory-sampler-test-#{System.unique_integer([:positive])}"
    attach_id = {__MODULE__, name}

    child_spec =
      Supervisor.child_spec(
        {MemorySampler,
         enabled?: true,
         name: name,
         attach_id: attach_id,
         limit_bytes: 100,
         cgroup_usage_reader: fn -> 0 end},
        id: name
      )

    start_supervised!(child_spec)

    assert memory_handler_attached?(attach_id)

    assert :ok = stop_supervised(name)

    refute memory_handler_attached?(attach_id)
  end

  defp memory_handler_attached?(attach_id) do
    [:vm, :memory]
    |> :telemetry.list_handlers()
    |> Enum.any?(&(&1.id == attach_id))
  end
end
