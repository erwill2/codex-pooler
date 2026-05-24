defmodule CodexPoolerWeb.Runtime.BackendCodexCompactionTriggerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  test "POST /backend-api/codex/responses keeps compaction_trigger on the normal SSE path", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{
               "id" => "resp_compaction_trigger_passthrough",
               "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
             }
           }}
        ])
      )

    setup = gateway_setup(upstream)
    sentinel = "compaction-trigger-sentinel-do-not-log"

    input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => sentinel}]
      },
      %{"type" => "compaction_trigger"}
    ]

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => input,
        "stream" => true
      })

    assert response(conn, 200) =~ "data: [DONE]

"
    assert FakeUpstream.count(upstream) == 1

    [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["model"] == setup.model.upstream_model_id
    assert captured.json["input"] == input

    request =
      Repo.one!(
        from(request in Request,
          where: request.pool_id == ^setup.pool.id,
          order_by: [desc: request.admitted_at],
          limit: 1
        )
      )

    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "http_sse"
    refute request.transport == "http_compact_json"
    refute request.endpoint == "/backend-api/codex/responses/compact"
  end
end
