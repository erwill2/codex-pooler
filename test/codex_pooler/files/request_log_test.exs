defmodule CodexPooler.Files.RequestLogTest do
  use CodexPooler.DataCase, async: true

  import ExUnit.CaptureLog

  alias CodexPooler.Files.{RequestLog, RequestMetadata}

  test "record_file_request returns sanitized accounting failures instead of raising" do
    request_metadata =
      RequestMetadata.build(
        %{
          request_id: Ecto.UUID.generate(),
          transport: "http_json",
          route_class: "file_upload"
        },
        "/backend-api/files"
      )

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} =
                 RequestLog.record_file_request(%{}, "failed", 502, request_metadata, %{
                   "operation" => "create"
                 })
      end)

    assert log =~ "operation=record_file_request"
    refute log =~ request_metadata.request_id
  end
end
