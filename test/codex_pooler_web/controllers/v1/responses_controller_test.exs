defmodule CodexPoolerWeb.V1.ResponsesControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  test "POST /v1/responses non-streaming dispatches through the gateway", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_non_stream",
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 response"
      })

    assert %{"id" => "resp_v1_non_stream", "object" => "response"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["stream"] == true
    assert captured.json["store"] == false

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.endpoint == "/backend-api/codex/responses"
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"
  end

  test "POST /v1/responses normalizes upstream JSON errors", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.failed",
           %{
             "type" => "response.failed",
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_request_error",
               "message" => "synthetic upstream validation"
             },
             "response" => %{"id" => "resp_v1_failed", "status" => "failed"}
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic rejected response"
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "invalid_request_error"
    assert error["message"] == "synthetic upstream validation"
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert [_attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
  end

  @tag :streaming_sequence
  test "POST /v1/responses streaming emits public Responses SSE and filters codex events", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"codex.rate_limits", %{"type" => "codex.rate_limits", "limits" => []}},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "visible text"}},
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_stream",
               "status" => "completed",
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic stream request",
        "stream" => true
      })

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.status == 200
    assert conn.resp_body =~ "event: response.created\n"
    assert conn.resp_body =~ "event: response.output_text.delta\n"
    assert conn.resp_body =~ "visible text"
    assert conn.resp_body =~ "event: response.completed\n"
    refute conn.resp_body =~ "codex.rate_limits"
    refute conn.resp_body =~ "event: codex."

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "http_sse"
    assert request.status == "succeeded"
  end

  test "POST /v1/responses streaming synthesizes missing delta from terminal output", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_v1_terminal_only",
               "status" => "completed",
               "output" => [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "terminal text"}]
                 }
               ],
               "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic terminal stream request",
        "stream" => true
      })

    assert conn.resp_body =~ "event: response.created\n"
    assert conn.resp_body =~ "event: response.output_text.delta\n"
    assert conn.resp_body =~ "terminal text"
    assert conn.resp_body =~ "event: response.completed\n"
  end

  @tag :startup_error
  test "POST /v1/responses streaming startup error returns OpenAI-shaped error", %{conn: conn} do
    upstream =
      start_upstream(
        {:json_error, 400,
         %{
           "error" => %{
             "code" => "invalid_request_error",
             "message" => "synthetic startup rejection"
           }
         }}
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic startup error request",
        "stream" => true
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "upstream_status"
    assert error["message"] == "upstream returned 400"
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
  end

  test "POST /v1/responses rejects unsupported logprobs before dispatch", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic invalid request",
        "logprobs" => true
      })

    assert %{"error" => error} = json_response(conn, 400)
    assert error["code"] == "unsupported_parameter"
    assert error["param"] == "logprobs"
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "POST /v1/responses/compact returns deterministic unsupported error without dispatch", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream, compact?: true)

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses/compact", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic compact request"
      })

    assert %{"error" => error} = json_response(conn, 404)
    assert error["code"] == "unsupported_endpoint"
    assert error["message"] == "Unsupported OpenAI /v1 endpoint"
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end
end
