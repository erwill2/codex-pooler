defmodule CodexPooler.Gateway.Routing.CandidateEligibility do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility.Quota
  alias CodexPooler.Gateway.Routing.{CircuitState, ModelMetadata}
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  defmodule FilterInput do
    @moduledoc false

    alias CodexPooler.Catalog.Model
    alias CodexPooler.Gateway.Payloads.RequestOptions
    alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

    @type auth :: CodexPooler.Access.auth_context()
    @type payload :: map()
    defstruct [
      :auth,
      :model,
      :endpoint,
      :payload,
      :request_options,
      :candidates,
      :route_class
    ]

    @type candidate :: {PoolUpstreamAssignment.t(), UpstreamIdentity.t()}
    @type attrs :: %{
            required(:model) => Model.t(),
            required(:endpoint) => String.t(),
            required(:payload) => payload(),
            required(:request_options) => RequestOptions.t(),
            required(:candidates) => [candidate()],
            optional(:auth) => auth()
          }

    @type t :: %__MODULE__{
            auth: auth() | nil,
            model: Model.t(),
            endpoint: String.t(),
            payload: payload(),
            request_options: RequestOptions.t(),
            candidates: [candidate()],
            route_class: String.t()
          }

    @spec new(attrs()) :: t()
    def new(attrs) when is_map(attrs) do
      endpoint = Map.fetch!(attrs, :endpoint)
      payload = Map.fetch!(attrs, :payload)
      request_options = request_options(attrs)

      %__MODULE__{
        auth: Map.get(attrs, :auth),
        model: Map.fetch!(attrs, :model),
        endpoint: endpoint,
        payload: payload,
        request_options: request_options,
        candidates: Map.fetch!(attrs, :candidates),
        route_class: request_options.transport.route_class
      }
    end

    @spec put_candidates(t(), [candidate()]) :: t()
    def put_candidates(%__MODULE__{} = input, candidates) when is_list(candidates),
      do: %{input | candidates: candidates}

    @spec put_request_options(t(), RequestOptions.t()) :: t()
    def put_request_options(%__MODULE__{} = input, %RequestOptions{} = request_options) do
      %{
        input
        | request_options: request_options,
          route_class: request_options.transport.route_class
      }
    end

    defp request_options(attrs) do
      %RequestOptions{} = request_options = Map.fetch!(attrs, :request_options)
      request_options
    end
  end

  @compact_support_key "supports_compact_responses"

  @type candidate :: {PoolUpstreamAssignment.t(), UpstreamIdentity.t()}
  @type gateway_error :: Contracts.gateway_error()
  @type quota_decision :: %{optional(String.t()) => term()}
  @type payload :: map()
  @type quota_refresh_plan :: %{
          required(:filter_input) => FilterInput.t(),
          required(:candidate_exclusions) => [map()],
          required(:refreshable_candidates) => [candidate()],
          optional(:route_state) => RouteState.t()
        }
  @type quota_filter_result ::
          {:ok, [candidate()], quota_decision()}
          | {:refreshable_quota, quota_refresh_plan()}

  @spec routable_candidates(Model.t()) ::
          {:ok, [candidate()]} | {:error, gateway_error()}
  def routable_candidates(%Model{} = model) do
    ids = source_assignment_ids(model)
    assignment_active_status = PoolUpstreamAssignment.active_status()
    assignment_active_health_status = PoolUpstreamAssignment.active_health_status()
    assignment_eligible_status = PoolUpstreamAssignment.eligible_status()
    identity_active_status = UpstreamIdentity.active_status()

    candidates =
      Repo.all(
        from assignment in PoolUpstreamAssignment,
          join: identity in UpstreamIdentity,
          on: identity.id == assignment.upstream_identity_id,
          where:
            assignment.id in ^ids and assignment.status == ^assignment_active_status and
              assignment.eligibility_status == ^assignment_eligible_status and
              assignment.health_status == ^assignment_active_health_status and
              identity.status == ^identity_active_status,
          order_by: [asc: assignment.created_at, asc: assignment.id],
          select: {assignment, identity}
      )

    if candidates == [],
      do:
        {:error,
         error(
           503,
           "no_eligible_backend",
           "no healthy eligible backend is currently available",
           "model"
         )},
      else: {:ok, candidates}
  end

  @spec filter_runtime_compatible_candidates(FilterInput.t()) ::
          {:ok, [candidate()]} | {:error, gateway_error()}
  def filter_runtime_compatible_candidates(%FilterInput{} = input) do
    %{
      model: model,
      endpoint: endpoint,
      payload: payload,
      request_options: request_options,
      candidates: candidates
    } = input

    requested_service_tier = requested_service_tier(payload, request_options)

    enforce_service_tier? = service_tier_requires_explicit_support?(requested_service_tier)

    candidates =
      Enum.filter(candidates, fn {assignment, _identity} ->
        assignment_compatible?(
          model,
          endpoint,
          payload,
          request_options,
          assignment,
          enforce_service_tier?
        )
      end)

    if candidates == [] do
      {:error,
       error(
         503,
         "no_compatible_backend",
         "no backend currently supports the requested model capabilities",
         "model"
       )}
    else
      {:ok, candidates}
    end
  end

  @spec maybe_filter_compact(String.t(), [candidate()]) :: {:ok, [candidate()]}
  def maybe_filter_compact("/backend-api/codex/responses/compact", candidates) do
    compact_candidates =
      Enum.filter(candidates, fn {assignment, identity} ->
        metadata_bool?(assignment.metadata, @compact_support_key) ||
          metadata_bool?(identity.metadata, @compact_support_key)
      end)

    case compact_candidates do
      [] -> {:ok, candidates}
      [_ | _] -> {:ok, compact_candidates}
    end
  end

  def maybe_filter_compact(_endpoint, candidates), do: {:ok, candidates}

  @spec filter_quota_eligible_candidates(FilterInput.t()) :: quota_filter_result()
  defdelegate filter_quota_eligible_candidates(input), to: Quota

  @spec filter_quota_eligible_candidates(FilterInput.t(), RouteState.t()) :: quota_filter_result()
  defdelegate filter_quota_eligible_candidates(input, route_state), to: Quota

  @spec quota_unavailable_error([map()], boolean()) :: {:error, gateway_error()}
  defdelegate quota_unavailable_error(exclusions, refresh_attempted?), to: Quota

  @spec filter_circuit_eligible_candidates(FilterInput.t()) ::
          {:ok, [candidate()]} | {:error, gateway_error()}
  def filter_circuit_eligible_candidates(%FilterInput{} = input) do
    %{
      auth: auth,
      model: model,
      candidates: candidates,
      route_class: route_class
    } = input

    {eligible, exclusions} =
      Enum.reduce(candidates, {[], []}, fn {assignment, identity} = candidate,
                                           {eligible, excluded} ->
        if CircuitState.eligible?(auth, model, assignment, route_class) do
          {[candidate | eligible], excluded}
        else
          {eligible,
           [
             %{
               pool_upstream_assignment_id: assignment.id,
               upstream_identity_id: identity.id,
               reasons: [%{"code" => "routing_circuit_open", "route_class" => route_class}]
             }
             | excluded
           ]}
        end
      end)

    case Enum.reverse(eligible) do
      [] ->
        {:error,
         error(
           503,
           "no_eligible_backend",
           "no healthy eligible backend is currently available",
           "model",
           %{candidate_exclusions: Enum.reverse(exclusions)}
         )}

      eligible ->
        {:ok, eligible}
    end
  end

  @spec filter_circuit_eligible_candidates(FilterInput.t(), RouteState.t()) ::
          {:ok, [candidate()]} | {:error, gateway_error()}
  def filter_circuit_eligible_candidates(%FilterInput{} = input, %RouteState{} = route_state) do
    %{candidates: candidates, route_class: route_class} = input

    {eligible, exclusions} =
      Enum.reduce(candidates, {[], []}, fn {assignment, identity} = candidate,
                                           {eligible, excluded} ->
        if RouteState.circuit_eligible?(route_state, assignment.id) do
          {[candidate | eligible], excluded}
        else
          {eligible,
           [
             %{
               pool_upstream_assignment_id: assignment.id,
               upstream_identity_id: identity.id,
               reasons: [%{"code" => "routing_circuit_open", "route_class" => route_class}]
             }
             | excluded
           ]}
        end
      end)

    case Enum.reverse(eligible) do
      [] ->
        {:error,
         error(
           503,
           "no_eligible_backend",
           "no healthy eligible backend is currently available",
           "model",
           %{candidate_exclusions: Enum.reverse(exclusions)}
         )}

      eligible ->
        {:ok, eligible}
    end
  end

  @spec payload_has_input_image?(payload()) :: boolean()
  def payload_has_input_image?(payload) do
    payload
    |> Map.get("input")
    |> has_input_image?()
  end

  defp source_assignment_ids(%Model{} = model) do
    case get_in(model.metadata || %{}, ["source_assignment_ids"]) do
      ids when is_list(ids) -> ids
      _value -> []
    end
  end

  defp assignment_compatible?(
         model,
         endpoint,
         payload,
         request_options,
         assignment,
         enforce_service_tier?
       ) do
    case source_assignment_model_metadata(model, assignment) do
      %{} = metadata ->
        endpoint_compatible?(endpoint, metadata) and streaming_compatible?(payload, metadata) and
          image_input_compatible?(payload, metadata) and tools_compatible?(payload, metadata) and
          reasoning_compatible?(payload, metadata) and
          service_tier_compatible?(payload, request_options, metadata, enforce_service_tier?)

      _value ->
        not enforce_service_tier?
    end
  end

  defp source_assignment_model_metadata(%Model{} = model, assignment) do
    get_in(model.metadata || %{}, ["source_assignment_models", assignment.id])
  end

  defp endpoint_compatible?("/backend-api/transcribe", metadata) do
    not ModelMetadata.has_capability_evidence?(metadata) or
      ModelMetadata.supports_audio_transcription?(metadata)
  end

  defp endpoint_compatible?(_endpoint, metadata) do
    not ModelMetadata.metadata_falsey?(ModelMetadata.metadata_map(metadata, "capabilities"), [
      "responses"
    ])
  end

  defp streaming_compatible?(payload, metadata) do
    not RouteClass.streaming?(payload) or
      not ModelMetadata.streaming_explicitly_unsupported?(metadata)
  end

  defp image_input_compatible?(payload, metadata) do
    not payload_has_input_image?(payload) or not ModelMetadata.has_capability_evidence?(metadata) or
      ModelMetadata.supports_image_input?(metadata)
  end

  defp tools_compatible?(payload, metadata) do
    not payload_has_tools?(payload) or ModelMetadata.supports_tools?(metadata)
  end

  defp reasoning_compatible?(payload, metadata) do
    not payload_has_reasoning?(payload) or ModelMetadata.supports_reasoning?(metadata)
  end

  defp service_tier_compatible?(_payload, _request_options, _metadata, false), do: true

  defp service_tier_compatible?(payload, request_options, metadata, true) do
    case requested_service_tier(payload, request_options) do
      nil -> true
      tier -> service_tier_supported?(metadata, tier)
    end
  end

  defp requested_service_tier(
         _payload,
         %RequestOptions{routing: %{api_key_policy: %{enforced_service_tier: tier}}}
       )
       when is_binary(tier) do
    clean_string(tier)
  end

  defp requested_service_tier(payload, _opts) do
    payload
    |> Map.get("service_tier")
    |> clean_string()
  end

  defp service_tier_supported?(metadata, tier) do
    tier = ModelMetadata.normalize_capability_value(tier)

    if tier in ["auto", "default"] do
      true
    else
      service_tier_explicitly_supported?(metadata, tier)
    end
  end

  defp service_tier_requires_explicit_support?(tier) when is_binary(tier) do
    tier = ModelMetadata.normalize_capability_value(tier)
    tier not in ["", "auto", "default"]
  end

  defp service_tier_requires_explicit_support?(_tier), do: false

  defp service_tier_explicitly_supported?(metadata, tier) do
    service_tiers =
      metadata
      |> ModelMetadata.list_metadata("service_tiers")
      |> Enum.map(&service_tier_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&ModelMetadata.normalize_capability_value/1)

    speed_tiers =
      metadata
      |> ModelMetadata.list_metadata("additional_speed_tiers")
      |> Enum.map(&ModelMetadata.normalize_capability_value/1)

    tier in service_tiers or tier in speed_tiers
  end

  defp service_tier_id(%{"id" => id}) when is_binary(id), do: id
  defp service_tier_id(tier) when is_binary(tier), do: tier
  defp service_tier_id(_tier), do: nil

  defp payload_has_tools?(payload) do
    case Map.get(payload, "tools") || Map.get(payload, :tools) do
      tools when is_list(tools) -> tools != []
      _value -> false
    end
  end

  defp payload_has_reasoning?(payload) do
    case Map.get(payload, "reasoning") || Map.get(payload, :reasoning) do
      value when is_map(value) -> map_size(value) > 0
      _value -> false
    end
  end

  defp has_input_image?(%{} = value) do
    value = Map.new(value, fn {key, item_value} -> {to_string(key), item_value} end)

    case value do
      %{"type" => "input_image"} -> true
      _value -> value |> Map.values() |> Enum.any?(&has_input_image?/1)
    end
  end

  defp has_input_image?(values) when is_list(values), do: Enum.any?(values, &has_input_image?/1)
  defp has_input_image?(_value), do: false

  defp metadata_bool?(metadata, key), do: Map.get(metadata || %{}, key) == true

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp error(status, code, message, param), do: error(status, code, message, param, %{})

  defp error(status, code, message, param, metadata),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
