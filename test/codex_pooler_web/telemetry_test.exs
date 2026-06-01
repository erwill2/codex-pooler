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
    assert "vm.memory.atom_used.bytes" in metric_names
    assert "vm.memory.code.bytes" in metric_names
    assert "vm.memory.system.bytes" in metric_names
    assert "vm.system_counts.process_count" in metric_names
    assert "vm.system_counts.port_count" in metric_names
    assert "vm.total_run_queue_lengths.cpu" in metric_names
    assert "vm.total_run_queue_lengths.io" in metric_names
  end

  test "exports Ecto repo query count and latency Prometheus metrics by source and command" do
    metrics = CodexPoolerWeb.Telemetry.prometheus_metrics()

    assert %Telemetry.Metrics.Counter{} =
             metric_by_name(metrics, "codex_pooler.repo.query.count")

    for name <- [
          "codex_pooler.repo.query.total_time.seconds",
          "codex_pooler.repo.query.query_time.seconds",
          "codex_pooler.repo.query.queue_time.seconds",
          "codex_pooler.repo.query.decode_time.seconds"
        ] do
      assert %Telemetry.Metrics.Distribution{
               event_name: [:codex_pooler, :repo, :query],
               tags: [:source, :command],
               reporter_options: reporter_options
             } = metric_by_name(metrics, name)

      assert Keyword.fetch!(reporter_options, :buckets) == [
               0.001,
               0.0025,
               0.005,
               0.01,
               0.025,
               0.05,
               0.1,
               0.25,
               0.5,
               1,
               2,
               5
             ]
    end
  end

  test "normalizes Ecto source tags without exposing SQL text" do
    metric =
      CodexPoolerWeb.Telemetry.prometheus_metrics()
      |> metric_by_name("codex_pooler.repo.query.count")

    assert %{source: "requests", command: "select"} =
             metric.tag_values.(%{source: "requests", query: "SELECT * FROM requests"})

    assert %{source: "requests", command: "insert"} =
             metric.tag_values.(%{query: ~s|INSERT INTO "requests" (id) VALUES ($1)|})

    assert %{source: "request_logs", command: "update"} =
             metric.tag_values.(%{query: "UPDATE request_logs SET updated_at = $1"})

    assert %{source: "unknown", command: "unknown"} = metric.tag_values.(%{})

    assert %{source: source} =
             metric.tag_values.(%{source: "SELECT * FROM requests WHERE secret = $1"})

    assert source == "unknown"
  end

  test "exports HTTP request and route counters with low-cardinality tags" do
    metrics = CodexPoolerWeb.Telemetry.prometheus_metrics()

    request_metric = metric_by_name(metrics, "codex_pooler.http.request.count")

    assert %Telemetry.Metrics.Counter{
             event_name: [:phoenix, :endpoint, :stop],
             tags: [:method, :status_class]
           } = request_metric

    assert %{method: "POST", status_class: "5xx"} =
             request_metric.tag_values.(%{conn: %{method: "POST", status: 503}})

    route_metric = metric_by_name(metrics, "codex_pooler.http.route.count")

    assert %Telemetry.Metrics.Counter{
             event_name: [:phoenix, :router_dispatch, :stop],
             tags: [:route, :method, :status_class]
           } = route_metric

    assert %{method: "GET", route: "/backend-api/codex/responses", status_class: "2xx"} =
             route_metric.tag_values.(%{
               conn: %{method: "GET", status: 200},
               route: "/backend-api/codex/responses"
             })

    assert %{method: "unknown", route: "unknown", status_class: "unknown"} =
             route_metric.tag_values.(%{conn: %{method: "unsafe method", status: nil}, route: ""})
  end

  test "exports gateway admission pressure metrics" do
    metrics = CodexPoolerWeb.Telemetry.prometheus_metrics()

    for {name, event} <- [
          {"codex_pooler.gateway.admission.accepted.count", :accepted},
          {"codex_pooler.gateway.admission.enqueued.count", :enqueued},
          {"codex_pooler.gateway.admission.dequeued.count", :dequeued},
          {"codex_pooler.gateway.admission.rejected.count", :rejected},
          {"codex_pooler.gateway.admission.timeout.count", :timeout}
        ] do
      assert %Telemetry.Metrics.Counter{
               event_name: [:codex_pooler, :gateway, :admission, ^event],
               tags: [:route_class, :transport]
             } = metric_by_name(metrics, name)
    end

    for {name, event} <- [
          {"codex_pooler.gateway.admission.dequeued_time.seconds", :dequeued},
          {"codex_pooler.gateway.admission.timeout_time.seconds", :timeout}
        ] do
      assert %Telemetry.Metrics.Distribution{
               event_name: [:codex_pooler, :gateway, :admission, ^event],
               tags: [:route_class, :transport],
               unit: :second,
               reporter_options: reporter_options
             } = metric_by_name(metrics, name)

      assert Keyword.fetch!(reporter_options, :buckets) == [
               0.005,
               0.01,
               0.025,
               0.05,
               0.1,
               0.25,
               0.5,
               1,
               2,
               5
             ]
    end

    metric = metric_by_name(metrics, "codex_pooler.gateway.admission.accepted.count")

    assert %{route_class: "runtime", transport: "http_sse"} =
             metric.tag_values.(%{route_class: "runtime", transport: "http_sse"})

    assert %{route_class: "unknown", transport: "unknown"} =
             metric.tag_values.(%{route_class: "unsafe class", transport: nil})
  end

  defp metric_by_name(metrics, name) do
    Enum.find(metrics, &(metric_name(&1) == name))
  end

  defp metric_name(metric) do
    Enum.map_join(metric.name, ".", &to_string/1)
  end
end
