defmodule CodexPoolerWeb.TelemetryTest do
  use ExUnit.Case, async: true

  test "starts telemetry poller with default VM measurements enabled" do
    assert {:ok, {_supervisor, children}} = CodexPoolerWeb.Telemetry.init(:ok)

    assert %{
             id: :telemetry_poller,
             start: {:telemetry_poller, :start_link, [[period: 10_000]]}
           } = Enum.find(children, &(&1.id == :telemetry_poller))
  end
end
