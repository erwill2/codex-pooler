defmodule CodexPooler.Gateway.Metadata do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Metadata.Accounting, as: MetadataAccounting
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.ModelMetadata

  @type auth :: Access.auth_context()
  @type opts :: RequestOptions.t()
  @type gateway_error :: Contracts.gateway_error()
  @type gateway_result :: Contracts.body_result()

  @spec serve_codex_models(auth(), opts()) :: {:ok, gateway_result()} | {:error, gateway_error()}
  def serve_codex_models(auth, %RequestOptions{} = request_options) do
    endpoint = request_endpoint(request_options, "/backend-api/codex/models")
    request_options = request_options(request_options, endpoint, %{})

    with {:ok, visible_models} <- policy_visible_models(auth, endpoint, request_options),
         :ok <-
           record_metadata_request(auth, endpoint, request_options, visible_models) do
      pricing_buckets = Catalog.pricing_buckets_by_identifier(visible_models)

      models = Enum.map(visible_models, &ModelMetadata.codex_model_payload(&1, pricing_buckets))

      {:ok, %{status: 200, headers: json_headers(), body: %{"models" => models}}}
    end
  end

  @spec serve_openai_models(auth(), opts()) :: {:ok, gateway_result()} | {:error, gateway_error()}
  def serve_openai_models(auth, %RequestOptions{} = request_options) do
    request_options = request_options(request_options, "/v1/models", %{})

    with {:ok, visible_models} <- policy_visible_models(auth, "/v1/models", request_options),
         :ok <- record_metadata_request(auth, "/v1/models", request_options, visible_models) do
      models = Enum.map(visible_models, &openai_model_payload/1)

      {:ok,
       %{
         status: 200,
         headers: json_headers(),
         body: %{"object" => "list", "data" => models}
       }}
    end
  end

  defp record_metadata_request(
         auth,
         endpoint,
         %RequestOptions{} = request_options,
         visible_models
       ) do
    request_metadata = request_options.request_metadata
    source_identity = Catalog.model_source_identity(visible_models)

    MetadataAccounting.record_metadata_request(:record_models_metadata_request, auth, %{
      endpoint: endpoint,
      transport: "http_json",
      correlation_id: RequestOptions.server_correlation_id(request_options),
      idempotency_key: request_metadata.idempotency_key,
      client_ip: request_metadata.client_ip,
      user_agent: request_metadata.user_agent,
      response_status_code: 200,
      upstream_identity: source_identity,
      request_metadata:
        %{
          "key_prefix" => auth.key_prefix,
          "endpoint" => endpoint,
          "operation" => "models",
          "model_source" => Catalog.model_source_snapshot(source_identity)
        }
        |> Map.merge(RequestOptions.client_request_metadata(request_options))
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    })
  end

  defp policy_visible_models(auth, endpoint, %RequestOptions{} = request_options) do
    with {:ok, policy} <- normalize_policy_or_log(auth, endpoint, request_options) do
      models =
        auth.pool
        |> Catalog.list_visible_models()
        |> Enum.filter(&model_visible_to_policy?(&1, policy))

      {:ok, models}
    end
  end

  defp model_visible_to_policy?(%Model{} = model, policy) do
    model_allowed_by_policy?(policy, model.exposed_model_id)
  end

  defp model_allowed_by_policy?(%{allowed_model_identifiers: nil}, _model), do: true
  defp model_allowed_by_policy?(%{allowed_model_identifiers: []}, _model), do: false

  defp model_allowed_by_policy?(%{allowed_model_identifiers: allowed}, model)
       when is_binary(model) do
    normalized = model |> String.trim() |> String.downcase()
    normalized in allowed
  end

  defp normalize_policy_or_log(auth, endpoint, %RequestOptions{} = request_options) do
    case Access.normalize_api_key_policy(auth.api_key) do
      {:ok, policy} ->
        {:ok, policy}

      {:error, reason} ->
        Denials.log_policy(denial_context(auth, reason, endpoint, request_options))
    end
  end

  defp denial_context(auth, reason, endpoint, %RequestOptions{} = request_options) do
    %Denials.Context{
      auth: auth,
      model: nil,
      reason: reason,
      endpoint: endpoint,
      payload: %{},
      opts: request_options
    }
  end

  defp openai_model_payload(%Model{} = model) do
    %{
      "id" => model.exposed_model_id,
      "object" => "model",
      "created" => openai_model_created_at(model),
      "owned_by" => "codex-pooler",
      "permission" => [],
      "input_modalities" => ModelMetadata.input_modalities(ModelMetadata.metadata(model)),
      "display_name" => model.display_name,
      "supports_streaming" => model.supports_streaming,
      "supports_tools" => model.supports_tools,
      "supports_reasoning" => model.supports_reasoning
    }
  end

  defp openai_model_created_at(%Model{} = model) do
    model.first_seen_at
    |> Kernel.||(DateTime.utc_now() |> DateTime.truncate(:second))
    |> DateTime.to_unix(:second)
  end

  defp request_endpoint(%RequestOptions{transport: %{upstream_endpoint: endpoint}}, _default)
       when is_binary(endpoint),
       do: endpoint

  defp request_endpoint(%RequestOptions{}, default), do: default

  defp request_options(%RequestOptions{} = request_options, endpoint, payload),
    do: RequestOptions.for_payload(request_options, endpoint, payload)

  defp json_headers, do: [{"content-type", "application/json"}]
end
