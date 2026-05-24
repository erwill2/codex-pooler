defmodule CodexPooler.Gateway.Payloads.FileRequestMetadataTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Files.RequestMetadata
  alias CodexPooler.Gateway.Payloads.{FileRequestMetadata, RequestOptions}

  describe "from_request_options/1" do
    test "projects only file-owned request metadata from gateway options" do
      now = DateTime.utc_now()

      request_options =
        %{
          client_ip: {127, 0, 0, 1},
          idempotency_key: "sample-idempotency-key",
          now: now,
          request_content_type: "application/json",
          request_id: "request-id",
          upload_bytes: 10,
          user_agent: "sample-client"
        }
        |> RequestOptions.build("/backend-api/files", %{"file_name" => "sample.txt"})
        |> RequestOptions.put_file_bridge(defer_create_request: true)

      assert %RequestMetadata{
               endpoint: "/backend-api/files",
               transport: "http_json",
               route_class: "file_upload",
               request_id: "request-id",
               idempotency_key: "sample-idempotency-key",
               client_ip: {127, 0, 0, 1},
               user_agent: "sample-client",
               request_bytes: request_bytes,
               upload_bytes: 10,
               request_content_type: "application/json",
               now: ^now,
               defer_create_request: true
             } = FileRequestMetadata.from_request_options(request_options)

      assert is_integer(request_bytes)
    end
  end
end
