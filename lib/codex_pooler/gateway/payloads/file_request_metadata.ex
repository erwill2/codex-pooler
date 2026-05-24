defmodule CodexPooler.Gateway.Payloads.FileRequestMetadata do
  @moduledoc false

  alias CodexPooler.Files.RequestMetadata
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @spec from_request_options(RequestOptions.t()) :: RequestMetadata.t()
  def from_request_options(%RequestOptions{} = request_options) do
    request_metadata = request_options.request_metadata
    transport = request_options.transport
    runtime = request_options.runtime
    file_bridge = request_options.file_bridge

    RequestMetadata.build(
      %{
        endpoint: transport.upstream_endpoint,
        transport: transport.transport,
        route_class: transport.route_class,
        request_id: request_metadata.request_id,
        idempotency_key: request_metadata.idempotency_key,
        client_ip: request_metadata.client_ip,
        user_agent: request_metadata.user_agent,
        request_bytes: request_metadata.request_bytes,
        upload_bytes: request_metadata.upload_bytes,
        request_content_type: request_metadata.request_content_type,
        now: runtime.now,
        defer_create_request: file_bridge.defer_create_request
      },
      transport.upstream_endpoint
    )
  end
end
