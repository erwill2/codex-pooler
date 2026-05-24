defmodule CodexPoolerWeb.Runtime.BackendFileProtocolTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [start_upstream: 1]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Gateway.Transports.FileBridge

  setup do
    old_config = Application.get_env(:codex_pooler, Files, [])
    old_bridge_config = Application.get_env(:codex_pooler, FileBridge, [])

    Application.put_env(:codex_pooler, Files,
      max_file_size_bytes: 64,
      file_ttl_seconds: 60
    )

    Application.put_env(:codex_pooler, FileBridge,
      finalize_retry_timeout_ms: 1_000,
      finalize_retry_interval_ms: 0
    )

    on_exit(fn ->
      Application.put_env(:codex_pooler, Files, old_config)
      Application.put_env(:codex_pooler, FileBridge, old_bridge_config)
    end)

    :ok
  end

  @tag :fake_upstream_file_protocol
  test "fake upstream file protocol captures create/finalize contract and error modes" do
    pool = pool_fixture()

    upstream_assignment =
      active_upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct_file_protocol_#{System.unique_integer([:positive])}"
      })

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_fake_protocol",
          file_name: "contract-fixture.txt",
          mime_type: "text/plain"
        )
      )

    headers = [
      {"authorization", "Bearer #{upstream_assignment.access_token}"},
      {"chatgpt-account-id", upstream_assignment.identity.chatgpt_account_id}
    ]

    create_response =
      Req.post!(FakeUpstream.url(upstream) <> "/backend-api/files",
        json: %{
          "file_name" => "contract-fixture.txt",
          "file_size" => 12,
          "use_case" => "user_data"
        },
        headers: headers
      )

    assert create_response.status == 200

    assert create_response.body == %{
             "file_id" => "file_fake_protocol",
             "upload_url" =>
               "https://fake-upload.invalid/upload/file_fake_protocol?sig=fake-upload"
           }

    finalize_response =
      Req.post!(FakeUpstream.url(upstream) <> "/backend-api/files/file_fake_protocol/uploaded",
        json: %{},
        headers: headers
      )

    assert finalize_response.status == 200

    assert finalize_response.body == %{
             "status" => "success",
             "download_url" =>
               "https://fake-download.invalid/download/file_fake_protocol?sig=fake-download",
             "file_name" => "contract-fixture.txt",
             "mime_type" => "text/plain"
           }

    assert [create_request, finalize_request] = FakeUpstream.requests(upstream)
    assert create_request.method == "POST"
    assert create_request.path == "/backend-api/files"

    assert create_request.json == %{
             "file_name" => "contract-fixture.txt",
             "file_size" => 12,
             "use_case" => "user_data"
           }

    assert finalize_request.path == "/backend-api/files/file_fake_protocol/uploaded"
    assert finalize_request.json == %{}

    assert header!(create_request.headers, "authorization") ==
             "Bearer #{upstream_assignment.access_token}"

    assert header!(create_request.headers, "chatgpt-account-id") ==
             upstream_assignment.identity.chatgpt_account_id

    refute header!(create_request.headers, "chatgpt-account-id") == "sentinel-account-id"

    unauthorized =
      start_upstream(FakeUpstream.file_protocol_unauthorized(file_id: "file_auth_error"))

    unauthorized_response =
      Req.post!(FakeUpstream.url(unauthorized) <> "/backend-api/files",
        json: %{"file_name" => "unauthorized.txt", "file_size" => 5, "use_case" => "user_data"},
        headers: headers,
        retry: false
      )

    assert unauthorized_response.status == 401
    assert unauthorized_response.body["error"]["code"] == "invalid_api_key"

    text_error =
      start_upstream(FakeUpstream.file_protocol_non_json_error(file_id: "file_text_error"))

    text_error_response =
      Req.post!(FakeUpstream.url(text_error) <> "/backend-api/files/file_text_error/uploaded",
        json: %{},
        headers: headers,
        decode_body: false,
        retry: false
      )

    assert text_error_response.status == 502
    assert text_error_response.body == "fake upstream file finalize failure"
  end

  @tag :fake_upstream_finalize_retry
  test "fake upstream finalize retry returns retry then success" do
    pool = pool_fixture()

    upstream_assignment =
      active_upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct_file_retry_#{System.unique_integer([:positive])}"
      })

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_finalize_retry(
          file_id: "file_retry_protocol",
          file_name: "retry-fixture.txt",
          mime_type: "text/plain"
        )
      )

    headers = [
      {"authorization", "Bearer #{upstream_assignment.access_token}"},
      {"chatgpt-account-id", upstream_assignment.identity.chatgpt_account_id}
    ]

    create_response =
      Req.post!(FakeUpstream.url(upstream) <> "/backend-api/files",
        json: %{"file_name" => "retry-fixture.txt", "file_size" => 21, "use_case" => "user_data"},
        headers: headers
      )

    assert create_response.body["file_id"] == "file_retry_protocol"

    first_finalize =
      Req.post!(FakeUpstream.url(upstream) <> "/backend-api/files/file_retry_protocol/uploaded",
        json: %{},
        headers: headers
      )

    assert first_finalize.status == 200
    assert first_finalize.body == %{"status" => "retry"}

    second_finalize =
      Req.post!(FakeUpstream.url(upstream) <> "/backend-api/files/file_retry_protocol/uploaded",
        json: %{},
        headers: headers
      )

    assert second_finalize.status == 200

    assert second_finalize.body == %{
             "status" => "success",
             "download_url" =>
               "https://fake-download.invalid/download/file_retry_protocol?sig=fake-download",
             "file_name" => "retry-fixture.txt",
             "mime_type" => "text/plain"
           }

    assert [create_request, first_finalize_request, second_finalize_request] =
             FakeUpstream.requests(upstream)

    assert create_request.path == "/backend-api/files"
    assert first_finalize_request.path == "/backend-api/files/file_retry_protocol/uploaded"
    assert second_finalize_request.path == "/backend-api/files/file_retry_protocol/uploaded"
  end

  defp header!(headers, name) do
    headers
    |> Enum.find_value(fn
      {^name, value} -> value
      _other -> nil
    end)
    |> case do
      nil -> flunk("missing header #{name}")
      value -> value
    end
  end
end
