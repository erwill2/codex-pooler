defmodule CodexPooler.MCP.RequestLogsToolsTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings, Redaction, ToolDispatch}
  alias CodexPooler.MCP.Tools.LogMetadata
  alias CodexPooler.Repo

  setup do
    reset_bootstrap_state_fixture!()
    Repo.delete_all(OperatorMCPKey)
    Repo.delete_all(OperatorMCPSettings)
    Repo.delete_all(CodexPooler.InstanceSettings.Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn -> InstanceSettings.reset_cache_for_test() end)

    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})

    user =
      user
      |> Ecto.Changeset.change(password_change_required: false)
      |> Repo.update!()

    settings = InstanceSettings.ensure_singleton!()
    assert {:ok, _updated} = InstanceSettings.update(settings, %{"mcp" => %{"enabled" => true}})
    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(user, true)

    assert {:ok, %{raw_token: raw_token}} = MCP.create_operator_token(user, %{label: "Logs MCP"})
    assert {:ok, auth} = MCP.authenticate_token(raw_token)

    %{auth: auth, user: user}
  end

  test "lists request-log metadata as bounded sanitized readable rows", %{auth: auth} do
    pool = pool_fixture(%{slug: "mcp-request-logs", name: "MCP Request Logs"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP runtime key"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{account_label: "Primary upstream"})

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-alpha",
        endpoint: "/backend-api/codex/responses",
        transport: "http_sse",
        status: "succeeded",
        usage_status: "usage_known",
        correlation_id: "mcp-request-log-alpha",
        response_status_code: 202,
        retry_count: 2,
        user_agent: "Codex CLI/1.2.3 extra raw details",
        upstream_account_email: "upstream.account@example.com",
        upstream_account_label: "stored-account-alpha",
        request_metadata: unsafe_metadata(%{"safe" => "visible metadata"})
      })

    attempt_with_latency(request, assignment, 345)

    _other_status =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-alpha",
        status: "failed",
        correlation_id: "mcp-request-log-failed"
      })

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{
                 "pool_id" => pool.id,
                 "status" => "succeeded",
                 "model" => "gpt-log-alpha",
                 "limit" => 1
               },
               %{auth: auth}
             )

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)

    assert [%{"type" => "text", "text" => text}] = result["content"]
    refute text =~ Jason.encode!(result["structuredContent"])

    structured = result["structuredContent"]

    assert Map.keys(structured) |> Enum.sort() == [
             "items",
             "limit",
             "nextOffset",
             "offset",
             "total"
           ]

    assert structured["total"] == 1
    assert structured["limit"] == 1
    assert structured["offset"] == 0
    assert structured["nextOffset"] == nil
    assert [item] = structured["items"]

    assert item["id"] == request.id
    assert item["pool_id"] == pool.id
    assert item["pool_slug"] == "mcp-request-logs"
    assert item["pool_name"] == "MCP Request Logs"
    assert item["status"] == "succeeded"
    assert item["endpoint"] == "/backend-api/codex/responses"
    assert item["requested_model"] == "gpt-log-alpha"
    assert item["transport"] == "http_sse"
    assert item["usage_status"] == "usage_known"
    assert item["latency_ms"] == 345
    assert item["retry_count"] == 2
    assert item["response_status_code"] == 202
    assert item["metadata"]["safe"] == "visible metadata"
    assert item["metadata"]["nested"]["count"] == 2
    assert item["metadata"]["nested"]["safe_sentinel"] == "[REDACTED]"
    refute Map.has_key?(item["metadata"], "prompt")
    refute Map.has_key?(item["metadata"], "raw_headers")
    refute Map.has_key?(item["metadata"], "request_body")
    refute Map.has_key?(item["metadata"], "raw_idempotency_key")
    refute Map.has_key?(item["metadata"]["nested"], "signed_url")

    assert text =~ "1 request logs returned; total 1; offset 0; statuses succeeded:1"
    assert text =~ "admitted_at=#{item["admitted_at"]}"
    assert text =~ "completed_at=#{item["completed_at"]}"
    assert text =~ "pool=mcp-request-logs"
    refute text =~ "pool_slug="
    refute text =~ "pool_name="
    assert text =~ "route=/backend-api/codex/responses"
    assert text =~ "status=succeeded"
    assert text =~ "model=gpt-log-alpha"
    assert text =~ "transport=http_sse"
    assert text =~ "usage=usage_known"
    assert text =~ "latency_ms=345"
    assert text =~ "retries=2"
    refute text =~ "retry_count="
    refute text =~ "metadata="

    assert_no_unsafe_request_log_text(result)
  end

  test "request-log list output schema accepts absent next page marker" do
    request_logs_tool =
      Enum.find(LogMetadata.tools(), &(&1.name == "codex_pooler_list_request_logs"))

    assert get_in(request_logs_tool.output_schema, ["properties", "nextOffset", "type"]) == [
             "integer",
             "null"
           ]
  end

  test "request-log list text handles empty results without echoing caller filters", %{auth: auth} do
    sentinels = caller_filter_sentinels()

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               Map.merge(sentinels, %{"limit" => 50, "offset" => 5}),
               %{auth: auth}
             )

    assert result["isError"] == false

    assert result["structuredContent"] == %{
             "items" => [],
             "total" => 0,
             "limit" => 50,
             "offset" => 5,
             "nextOffset" => nil
           }

    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text == "0 request logs returned; total 0; offset 5; statuses none"

    for {_field, sentinel} <- sentinels do
      refute text =~ sentinel
      refute inspect(result) =~ sentinel
    end

    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "request-log list accepts full ISO8601 timestamp range filters", %{auth: auth} do
    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{
                 "date_from" => "2026-05-23T02:23:30Z",
                 "date_to" => "2026-05-23T02:26:20Z",
                 "request_id" => "f5da8450",
                 "limit" => 20,
                 "offset" => 0
               },
               %{auth: auth}
             )

    assert result["isError"] == false

    assert result["structuredContent"] == %{
             "items" => [],
             "total" => 0,
             "limit" => 20,
             "offset" => 0,
             "nextOffset" => nil
           }

    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text == "0 request logs returned; total 0; offset 0; statuses none"
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "request-log list text is capped when structured content contains more than ten rows", %{
    auth: auth
  } do
    pool = pool_fixture(%{slug: "mcp-request-log-over-limit", name: "MCP Request Log Over Limit"})
    %{api_key: api_key} = active_api_key_fixture(pool)

    for index <- 1..12 do
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-over-limit",
        endpoint: "/backend-api/codex/responses",
        status: "succeeded",
        correlation_id: "mcp-request-log-over-limit-#{index}"
      })
    end

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{"pool_id" => pool.id, "model" => "gpt-log-over-limit", "limit" => 12},
               %{auth: auth}
             )

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    assert length(result["structuredContent"]["items"]) == 12
    assert result["structuredContent"]["total"] == 12

    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "10 request logs returned; total 12; offset 0; statuses succeeded:12"
    assert text =~ "- ... 2 more rows omitted from text; use structuredContent or refine filters"

    row_count =
      text
      |> String.split("\n")
      |> Enum.count(&String.starts_with?(&1, "- admitted_at="))

    assert row_count == 10
    refute text =~ Jason.encode!(result["structuredContent"])
  end

  test "request-log tool rejects malformed semantic filters without echoing date sentinels", %{
    auth: auth
  } do
    date_sentinel = "#{Redaction.forbidden_sentinel!(:request_body)}-not-a-date"

    assert {:ok, result} =
             ToolDispatch.call(
               "codex_pooler_list_request_logs",
               %{
                 "date_from" => date_sentinel,
                 "date_to" => Redaction.forbidden_sentinel!(:raw_headers)
               },
               %{auth: auth}
             )

    assert result["isError"] == true
    assert get_in(result, ["structuredContent", "error", "code"]) == "invalid_arguments"
    refute inspect(result) =~ date_sentinel
    refute inspect(result) =~ Redaction.forbidden_sentinel!(:raw_headers)
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "gets one request-log metadata record with readable detail fields and safe metadata summary",
       %{
         auth: auth
       } do
    pool = pool_fixture(%{slug: "mcp-request-log-detail", name: "MCP Request Log Detail"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP detail key"})

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Detail upstream",
        assignment_label: "Detail assignment"
      })

    long_metadata = String.duplicate("safe-detail-value", 30)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-detail",
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        status: "failed",
        usage_status: "usage_unknown",
        correlation_id: "mcp-request-log-detail",
        response_status_code: 499,
        retry_count: 3,
        upstream_account_email: "detail.account@example.com",
        upstream_account_label: "detail-account-label",
        request_metadata: unsafe_metadata(%{"safe" => long_metadata})
      })

    attempt_with_latency(request, assignment, 678)

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => request.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    assert [%{"type" => "text", "text" => text}] = result["content"]
    refute text =~ Jason.encode!(result["structuredContent"])

    assert %{"status" => "ok", "kind" => "request_log", "item" => item} =
             result["structuredContent"]

    assert Map.keys(result["structuredContent"]) |> Enum.sort() == [
             "candidates",
             "item",
             "kind",
             "message",
             "status"
           ]

    assert item["id"] == request.id
    assert item["pool_id"] == pool.id
    assert item["endpoint"] == "/backend-api/codex/responses"
    assert item["status"] == "failed"
    assert item["response_status_code"] == 499
    assert item["upstream_identity_label"] == "Detail upstream"
    assert item["upstream_account_label"] == "detail-account-label"
    assert item["metadata"]["safe"] == String.slice(long_metadata, 0, 200)
    refute Map.has_key?(item["metadata"], "prompt")
    refute Map.has_key?(item["metadata"], "raw_headers")

    assert text =~ "1 request log returned"
    assert text =~ "admitted_at=#{item["admitted_at"]}"
    assert text =~ "completed_at=#{item["completed_at"]}"
    assert text =~ "pool=mcp-request-log-detail"
    refute text =~ "pool_slug="
    refute text =~ "pool_name="
    assert text =~ "route=/backend-api/codex/responses"
    assert text =~ "status=failed"
    assert text =~ "model=gpt-log-detail"
    assert text =~ "transport=websocket"
    assert text =~ "usage=usage_unknown"
    assert text =~ "latency_ms=678"
    assert text =~ "retries=3"
    assert text =~ "response=499"
    assert text =~ "upstream=Detail upstream"
    refute text =~ "retry_count="
    refute text =~ "response_status="
    refute text =~ "account="
    assert text =~ "metadata=2 safe metadata keys: nested, safe"
    refute text =~ long_metadata

    assert_no_unsafe_request_log_text(result)
  end

  test "request-log get text handles nil optional fields and missing selectors", %{auth: auth} do
    pool = pool_fixture(%{slug: "mcp-request-log-nil", name: "MCP Request Log Nil"})
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "MCP nil key"})

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-nil",
        endpoint: "/backend-api/codex/responses",
        status: "in_progress",
        usage_status: "usage_pending",
        completed_at: nil,
        response_status_code: nil,
        retry_count: nil,
        correlation_id: "mcp-request-log-nil",
        request_metadata: %{}
      })

    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => request.id}, %{
               auth: auth
             })

    assert result["isError"] == false
    assert :ok = Redaction.assert_mcp_output_safe!(result)
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "1 request log returned"
    assert text =~ "admitted_at="
    assert text =~ "pool=mcp-request-log-nil"
    refute text =~ "pool_slug="
    refute text =~ "pool_name="
    assert text =~ "status=in_progress"
    assert text =~ "model=gpt-log-nil"
    assert text =~ "transport=http_json"
    refute text =~ "completed_at="
    assert text =~ "usage=usage_pending"
    refute text =~ "latency_ms="
    assert text =~ "retries=0"
    assert text =~ "upstream=unknown"
    refute text =~ "retry_count="
    refute text =~ "response_status="
    refute text =~ "response="
    refute text =~ "account="
    refute text =~ "metadata="

    missing_selector = "sk-cxp-secret-missing-selector"

    assert {:ok, missing} =
             ToolDispatch.call("codex_pooler_get_request_log", %{"id" => missing_selector}, %{
               auth: auth
             })

    assert missing["isError"] == false

    assert missing["structuredContent"] == %{
             "status" => "not_found",
             "kind" => "request_log",
             "item" => nil,
             "candidates" => [],
             "message" => "request_log selector did not match"
           }

    assert [%{"type" => "text", "text" => missing_text}] = missing["content"]
    assert missing_text == "No visible request log matched the selector"
    refute inspect(missing) =~ missing_selector
    assert :ok = Redaction.assert_mcp_output_safe!(missing)
  end

  defp attempt_with_latency(request, assignment, latency_ms) do
    request
    |> attempt_fixture(assignment)
    |> Ecto.Changeset.change(latency_ms: latency_ms)
    |> Repo.update!()
  end

  defp unsafe_metadata(extra) do
    Map.merge(
      %{
        "prompt" => Redaction.forbidden_sentinel!(:prompt),
        "raw_headers" => %{"authorization" => Redaction.forbidden_sentinel!(:raw_headers)},
        "request_body" => Redaction.forbidden_sentinel!(:request_body),
        "response_body" => Redaction.forbidden_sentinel!(:response_body),
        "access_token" => Redaction.forbidden_sentinel!(:access_token),
        "raw_idempotency_key" => Redaction.forbidden_sentinel!(:raw_idempotency_key),
        "raw_email_value" => "unsafe.request.log@example.com",
        "raw_ip_value" => "192.0.2.44",
        "raw_url_value" => "https://uploads.example.com/request-log-unsafe",
        "nested" => %{
          "count" => 2,
          "signed_url" => Redaction.forbidden_sentinel!(:upload_url),
          "safe_sentinel" => Redaction.forbidden_sentinel!(:response_body)
        }
      },
      extra
    )
  end

  defp caller_filter_sentinels do
    %{
      "pool_id" => Redaction.forbidden_sentinel!(:raw_pool_api_key),
      "status" => Redaction.forbidden_sentinel!(:prompt),
      "model" => Redaction.forbidden_sentinel!(:raw_headers),
      "request_id" => Redaction.forbidden_sentinel!(:request_body),
      "upstream_identity_id" => Redaction.forbidden_sentinel!(:access_token)
    }
  end

  defp assert_no_unsafe_request_log_text(result) do
    inspected = inspect(result)

    refute inspected =~ "unsafe.request.log@example.com"
    refute inspected =~ "upstream.account@example.com"
    refute inspected =~ "detail.account@example.com"
    refute inspected =~ "192.0.2.44"
    refute inspected =~ "https://uploads.example.com/request-log-unsafe"
    refute inspected =~ Redaction.forbidden_sentinel!(:prompt)
    refute inspected =~ Redaction.forbidden_sentinel!(:raw_headers)
    refute inspected =~ Redaction.forbidden_sentinel!(:request_body)
    refute inspected =~ Redaction.forbidden_sentinel!(:response_body)
    refute inspected =~ Redaction.forbidden_sentinel!(:access_token)
    refute inspected =~ Redaction.forbidden_sentinel!(:raw_idempotency_key)
    refute inspected =~ Redaction.forbidden_sentinel!(:upload_url)
  end
end
