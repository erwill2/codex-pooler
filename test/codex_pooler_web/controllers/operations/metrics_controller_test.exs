defmodule CodexPoolerWeb.Operations.MetricsControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Repo

  defmodule FailingRepo do
    def insert(_struct, _opts),
      do: raise(DBConnection.ConnectionError, message: "settings db unavailable")

    def get!(_schema, _id),
      do: raise(DBConnection.ConnectionError, message: "settings db unavailable")
  end

  setup do
    previous = Application.get_env(:codex_pooler, InstanceSettings, [])
    Application.put_env(:codex_pooler, InstanceSettings, Keyword.delete(previous, :repo))
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      Application.put_env(:codex_pooler, InstanceSettings, previous)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  test "allows open metrics access when bearer token is intentionally unset", %{conn: conn} do
    conn = get(conn, ~p"/metrics")

    assert conn.status == 200
    assert metrics_content_type?(conn)
  end

  test "allows open metrics access when a configured bearer token is cleared", %{conn: conn} do
    configure_metrics_token!("metrics-secret")

    assert {:ok, _updated} =
             InstanceSettings.update(
               InstanceSettings.get!(),
               InstanceSettings.clear_metrics_bearer_token(%{})
             )

    conn = get(conn, ~p"/metrics")

    assert conn.status == 200
    assert metrics_content_type?(conn)
  end

  test "rejects metrics access when configured bearer token is missing", %{conn: conn} do
    configure_metrics_token!("metrics-secret")

    conn = get(conn, ~p"/metrics")

    assert conn.status == 401
    assert json_response(conn, 401)["error"]["code"] == "metrics_unauthorized"
  end

  test "rejects metrics access when configured bearer token is wrong", %{conn: conn} do
    configure_metrics_token!("metrics-secret")

    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong-secret")
      |> get(~p"/metrics")

    assert conn.status == 401
    assert json_response(conn, 401)["error"]["code"] == "metrics_unauthorized"
  end

  test "allows metrics access with the configured bearer token", %{conn: conn} do
    configure_metrics_token!("metrics-secret")

    conn =
      conn
      |> put_req_header("authorization", "Bearer metrics-secret")
      |> get(~p"/metrics")

    assert conn.status == 200
    assert metrics_content_type?(conn)
  end

  test "rotating the metrics bearer token invalidates the old bearer", %{conn: conn} do
    configure_metrics_token!("metrics-secret-v1")
    configure_metrics_token!("metrics-secret-v2")

    rejected =
      conn
      |> put_req_header("authorization", "Bearer metrics-secret-v1")
      |> get(~p"/metrics")

    assert rejected.status == 401
    assert json_response(rejected, 401)["error"]["code"] == "metrics_unauthorized"

    allowed =
      build_conn()
      |> put_req_header("authorization", "Bearer metrics-secret-v2")
      |> get(~p"/metrics")

    assert allowed.status == 200
    assert metrics_content_type?(allowed)
  end

  test "fails closed when metrics settings are unavailable", %{conn: conn} do
    Application.put_env(:codex_pooler, InstanceSettings, repo: FailingRepo)
    InstanceSettings.reset_cache_for_test()

    {conn, log} = with_instance_settings_db_failure_log(fn -> get(conn, ~p"/metrics") end)

    assert log =~ "instance settings db load failed warm_cache=false"
    assert conn.status == 401
    assert json_response(conn, 401)["error"]["code"] == "metrics_unauthorized"
    assert json_response(conn, 401)["error"]["message"] == "metrics bearer token is unavailable"
  end

  defp with_instance_settings_db_failure_log(fun) do
    ref = make_ref()

    log =
      capture_log(fn ->
        send(self(), {ref, fun.()})
      end)

    assert_received {^ref, result}
    {result, log}
  end

  defp metrics_content_type?(conn) do
    conn
    |> get_resp_header("content-type")
    |> List.first()
    |> String.starts_with?("text/plain")
  end

  defp configure_metrics_token!(token) do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update(
               settings,
               InstanceSettings.put_metrics_bearer_token(%{}, token)
             )
  end
end
