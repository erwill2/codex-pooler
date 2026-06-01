defmodule CodexPoolerWeb.TelemetryTest do
  use ExUnit.Case, async: true

  test "starts telemetry poller with default VM measurements enabled" do
    assert {:ok, {_supervisor, children}} = CodexPoolerWeb.Telemetry.init(:ok)

    assert %{
             id: :telemetry_poller,
             start: {:telemetry_poller, :start_link, [[period: 10_000]]}
           } = Enum.find(children, &(&1.id == :telemetry_poller))
  end

  test "exports BEAM memory category and process count Prometheus metrics" do
    metric_names =
      CodexPoolerWeb.Telemetry.prometheus_metrics()
      |> Enum.map(&metric_name/1)

    assert "vm.memory.total.bytes" in metric_names
    assert "vm.memory.processes.bytes" in metric_names
    assert "vm.memory.processes_used.bytes" in metric_names
    assert "vm.memory.binary.bytes" in metric_names
    assert "vm.memory.ets.bytes" in metric_names
    assert "vm.memory.atom.bytes" in metric_names
    assert "vm.memory.code.bytes" in metric_names
    assert "vm.system_counts.process_count" in metric_names
    assert "vm.system_counts.port_count" in metric_names
  end

  defp metric_name(metric) do
    Enum.map_join(metric.name, ".", &to_string/1)
  end
end
