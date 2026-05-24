defmodule CodexPooler.Gateway.ControlPlaneProxy.Metadata do
  @moduledoc false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.ControlPlaneProxy
  alias CodexPooler.Gateway.ControlPlaneProxy.Request, as: ProxyRequest
  alias CodexPooler.Gateway.Metadata.Accounting, as: MetadataAccounting
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.RoutingSelection

  @type auth :: ControlPlaneProxy.auth()
  @type gateway_error :: ControlPlaneProxy.gateway_error()

  @spec record_disabled_analytics(auth(), ProxyRequest.t()) ::
          {:ok, map()} | {:error, gateway_error()}
  def record_disabled_analytics(auth, %ProxyRequest{} = request) do
    body = request.body
    request_options = metadata_request_options(request, body)

    request_metadata = %{
      "endpoint" => request.local_endpoint,
      "routing" => %{"route_class" => request_options.transport.route_class},
      "request" => %{
        "body_bytes" => byte_size(body),
        "content_type" => request_options.request_metadata.request_content_type
      },
      "control_plane" => %{"analytics_forwarding" => "disabled"}
    }

    with :ok <-
           MetadataAccounting.record_metadata_request(:record_disabled_analytics_request, auth, %{
             endpoint: request.local_endpoint,
             transport: "http_json",
             status: "succeeded",
             correlation_id: request_options.request_metadata.request_id,
             client_ip: request_options.request_metadata.client_ip,
             user_agent: request_options.request_metadata.user_agent,
             response_status_code: 204,
             retry_count: 0,
             request_metadata: request_metadata
           }) do
      {:ok, %{status: 204, headers: [], raw_body: ""}}
    end
  end

  @spec record_request(
          auth(),
          ProxyRequest.t(),
          Model.t(),
          RoutingSelection.t(),
          RequestOptions.t(),
          Req.Response.t(),
          non_neg_integer(),
          map() | nil
        ) :: :ok | {:error, gateway_error()}
  def record_request(
        auth,
        request,
        model,
        selection,
        request_options,
        response,
        retry_count,
        refresh_metadata
      ) do
    status = if response.status in 200..299, do: "succeeded", else: "failed"
    last_error_code = if status == "failed", do: status_error_code(response.status)

    request_metadata =
      control_plane_request_metadata(request, model, selection, request_options, refresh_metadata)

    MetadataAccounting.record_metadata_request(
      :record_control_plane_metadata_request,
      auth,
      metadata_request_attrs(
        request,
        request_options,
        status,
        response.status,
        retry_count,
        last_error_code,
        selection,
        request_metadata
      )
    )
  end

  @spec record_failed_request(
          auth(),
          ProxyRequest.t(),
          Model.t(),
          RoutingSelection.t(),
          RequestOptions.t(),
          non_neg_integer(),
          map() | nil,
          String.t()
        ) :: :ok | {:error, gateway_error()}
  def record_failed_request(
        auth,
        request,
        model,
        selection,
        request_options,
        retry_count,
        refresh_metadata,
        code
      ) do
    request_metadata =
      request
      |> control_plane_request_metadata(model, selection, request_options, refresh_metadata)
      |> Map.update("control_plane", %{"dispatch_error" => code}, fn metadata ->
        Map.put(metadata || %{}, "dispatch_error", code)
      end)

    MetadataAccounting.record_metadata_request(
      :record_control_plane_failure_metadata_request,
      auth,
      metadata_request_attrs(
        request,
        request_options,
        "failed",
        502,
        retry_count,
        code,
        selection,
        request_metadata
      )
    )
  end

  defp metadata_request_attrs(
         request,
         request_options,
         status,
         response_status_code,
         retry_count,
         last_error_code,
         selection,
         request_metadata
       ) do
    %{
      endpoint: request.local_endpoint,
      transport: "http_json",
      status: status,
      correlation_id: request_options.request_metadata.request_id,
      client_ip: request_options.request_metadata.client_ip,
      user_agent: request_options.request_metadata.user_agent,
      response_status_code: response_status_code,
      retry_count: retry_count,
      last_error_code: last_error_code,
      upstream_identity: selection.identity,
      request_metadata: request_metadata
    }
  end

  defp control_plane_request_metadata(
         request,
         model,
         selection,
         request_options,
         refresh_metadata
       ) do
    selection.route_metadata
    |> Map.update("routing", control_plane_routing_metadata(model, selection), fn routing ->
      Map.merge(routing, control_plane_routing_metadata(model, selection))
    end)
    |> Map.merge(%{
      "endpoint" => request.local_endpoint,
      "request" => %{
        "body_bytes" => byte_size(request.body),
        "content_type" => request_options.request_metadata.request_content_type
      },
      "auth_refresh" => refresh_metadata
    })
  end

  defp control_plane_routing_metadata(model, selection) do
    %{
      "selected_assignment_id" => selection.assignment.id,
      "upstream_identity_id" => selection.identity.id,
      "model" => model.exposed_model_id
    }
  end

  defp status_error_code(401), do: "upstream_unauthorized"
  defp status_error_code(status) when status >= 500, do: "upstream_5xx"
  defp status_error_code(_status), do: "upstream_status"

  defp metadata_request_options(%ProxyRequest{} = request, body) do
    request.request_opts
    |> Map.merge(%{request_bytes: byte_size(body), transport: "http_json"})
    |> RequestOptions.build(request.local_endpoint, %{})
  end
end
