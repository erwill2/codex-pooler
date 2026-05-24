defmodule CodexPooler.Files.RequestMetadataTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Files.RequestMetadata

  describe "build/2" do
    test "keeps file-facing request metadata without gateway option ownership" do
      now = DateTime.utc_now()

      metadata =
        RequestMetadata.build(
          [
            endpoint: "/backend-api/files",
            transport: "http_json",
            route_class: "file_upload",
            request_id: "request-id",
            idempotency_key: "idempotency-key",
            client_ip: {127, 0, 0, 1},
            user_agent: "sample-client",
            request_bytes: 42,
            upload_bytes: 24,
            request_content_type: "application/json",
            now: now,
            defer_create_request: true
          ],
          "/v1/files"
        )

      assert %RequestMetadata{
               endpoint: "/backend-api/files",
               transport: "http_json",
               route_class: "file_upload",
               request_id: "request-id",
               idempotency_key: "idempotency-key",
               client_ip: {127, 0, 0, 1},
               user_agent: "sample-client",
               request_bytes: 42,
               upload_bytes: 24,
               request_content_type: "application/json",
               now: ^now,
               defer_create_request: true
             } = metadata
    end

    test "fills the default endpoint when callers provide no endpoint" do
      assert %RequestMetadata{endpoint: "/v1/files"} = RequestMetadata.build(%{}, "/v1/files")
    end
  end
end
