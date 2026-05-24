defmodule CodexPoolerWeb.Runtime.GatewayControllerHelpersTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import CodexPooler.PoolerFixtures

  alias CodexPoolerWeb.Runtime.GatewayControllerHelpers

  test "body results do not require a headers key", %{conn: conn} do
    conn =
      GatewayControllerHelpers.send_gateway_result(conn, %{
        status: 200,
        body: %{"ok" => true}
      })

    assert json_response(conn, 200) == %{"ok" => true}
  end

  test "raw body results do not require a headers key", %{conn: conn} do
    conn =
      GatewayControllerHelpers.send_gateway_result(conn, %{
        status: 200,
        raw_body: "raw"
      })

    assert response(conn, 200) == "raw"
  end

  test "send_or_error accepts conn first", %{conn: conn} do
    conn =
      GatewayControllerHelpers.send_or_error(conn, {
        :ok,
        %{status: 200, body: %{"ok" => true}}
      })

    assert json_response(conn, 200) == %{"ok" => true}
  end

  test "authenticate_v1 keeps OpenAI /v1 API-key eligibility separate from backend auth" do
    setup = paused_api_key_fixture()

    conn =
      Phoenix.ConnTest.build_conn(:get, "/v1/models")
      |> put_req_header("authorization", setup.authorization)

    assert {:error, %{status: 401, code: :api_key_paused}} =
             GatewayControllerHelpers.authenticate(conn)

    assert {:error, %{status: 401, code: :api_key_disabled}} =
             GatewayControllerHelpers.authenticate_v1(conn)
  end

  test "late stream errors preserve a safe log reason" do
    conn =
      Phoenix.ConnTest.build_conn(:post, "/backend-api/codex/responses")
      |> put_req_header("x-request-id", "late-stream-regression")

    log =
      capture_log(fn ->
        conn =
          GatewayControllerHelpers.send_gateway_result(conn, %{
            status: 200,
            stream: fn _conn -> {:error, {:chunk, :closed}} end
          })

        assert conn.state == :chunked
      end)

    assert log =~ "late gateway stream failed"
    assert log =~ "path=/backend-api/codex/responses"
    assert log =~ "request_id=late-stream-regression"
    assert log =~ "client disconnected while writing downstream stream"
  end

  test "result_headers normalizes nil or missing headers" do
    assert GatewayControllerHelpers.result_headers(%{}) == []
    assert GatewayControllerHelpers.result_headers(%{headers: nil}) == []

    assert GatewayControllerHelpers.result_headers(%{headers: [{"x-example", "ok"}]}) == [
             {"x-example", "ok"}
           ]
  end
end
