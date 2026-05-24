defmodule CodexPooler.Gateway.ControlPlaneProxyTest do
  use CodexPooler.DataCase, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.ControlPlaneProxy
  alias CodexPooler.Gateway.ControlPlaneProxy.Metadata

  describe "build_request!/1" do
    test "normalizes nested request opts into a map" do
      request =
        ControlPlaneProxy.build_request!(
          local_endpoint: "/backend-api/codex/thread/goal/get",
          upstream_endpoint: "/codex/thread/goal/get",
          method: "GET",
          request_opts: [request_id: "control-plane-request"]
        )

      assert request.request_opts == %{request_id: "control-plane-request"}
    end
  end

  describe "record_disabled_analytics/2" do
    test "surfaces metadata accounting failures through both module contracts" do
      request =
        ControlPlaneProxy.build_request!(
          local_endpoint: "/backend-api/codex/analytics-events/events",
          upstream_endpoint: "/codex/analytics-events/events",
          method: "POST",
          body: ~s({"events":[]}),
          body_mode: {:json, :object},
          request_headers: [],
          request_opts: %{}
        )

      log =
        capture_log(fn ->
          assert {:error, gateway_error} =
                   ControlPlaneProxy.record_disabled_analytics(%{}, request)

          assert gateway_error.status == 500
          assert gateway_error.code == "gateway_accounting_failed"

          assert {:error, ^gateway_error} = Metadata.record_disabled_analytics(%{}, request)
        end)

      assert log =~ "operation=record_disabled_analytics_request"
    end
  end
end
