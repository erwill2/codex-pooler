defmodule CodexPoolerWeb.Plugs.AdminBrowserAdmissionTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.Plugs.AdminBrowserAdmission

  setup do
    old_config = Application.get_env(:codex_pooler, OperationalSettings)
    Admission.reset_for_test()
    Application.put_env(:codex_pooler, OperationalSettings, settings: settings())

    on_exit(fn ->
      Admission.reset_for_test()

      if old_config do
        Application.put_env(:codex_pooler, OperationalSettings, old_config)
      else
        Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end)
  end

  test "overloaded browser lane returns sanitized text response", %{conn: conn} do
    assert {:ok, lease} =
             Admission.acquire(RouteClass.admin_browser(), %{request_id: "held-browser"})

    conn =
      conn
      |> Map.put(:path_info, ["admin", "pools"])
      |> Map.put(:method, "GET")
      |> AdminBrowserAdmission.call([])

    assert conn.halted
    assert conn.status == 503
    assert conn.resp_body == "gateway route class is temporarily overloaded"
    refute conn.resp_body =~ "held-browser"

    Admission.release(lease)
  end

  defp settings do
    %OperationalSettings{
      bulkheads:
        Map.new(Admission.route_classes(), fn route_class ->
          {route_class, %{max_concurrency: 4, queue_limit: 4, queue_timeout_ms: 1_000}}
        end)
        |> Map.put(RouteClass.admin_browser(), %{
          max_concurrency: 1,
          queue_limit: 0,
          queue_timeout_ms: 1_000
        })
    }
  end
end
