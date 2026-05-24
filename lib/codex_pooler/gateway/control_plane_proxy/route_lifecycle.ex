defmodule CodexPooler.Gateway.ControlPlaneProxy.RouteLifecycle do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.ControlPlaneProxy
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Routing.{
    CandidateEligibility,
    RouteFiltering,
    RouteLifecycle,
    RoutePlanInput,
    RoutingSelection
  }

  alias CodexPooler.Pools

  @control_plane_model_identifier "__control_plane__"

  @type auth :: ControlPlaneProxy.auth()
  @type gateway_error :: ControlPlaneProxy.gateway_error()

  @spec select_and_begin_route(auth(), String.t(), RequestOptions.t()) ::
          {:ok, Model.t(), RoutingSelection.t(), RequestOptions.t()} | {:error, gateway_error()}
  def select_and_begin_route(auth, endpoint, %RequestOptions{} = request_options) do
    with {:ok, model} <- control_plane_route_model(auth),
         {:ok, candidates} <- CandidateEligibility.routable_candidates(model),
         {:ok, candidates, request_options} <-
           route_filter_input(auth, model, endpoint, request_options, candidates)
           |> RouteFiltering.filter_candidates(quota_mode: :optional),
         {:ok, selection} <-
           RoutingSelection.select_and_begin_circuit(%{
             auth: auth,
             model: model,
             candidates: candidates,
             route_plan_input: RoutePlanInput.from_request_opts(request_options),
             endpoint: endpoint,
             payload: %{},
             request_options: request_options
           }) do
      {:ok, model, selection, request_options}
    else
      {:error, %{status: _status} = reason} ->
        {:error, reason}

      {:error, %{code: :no_eligible_backend}} ->
        {:error, no_eligible_backend_error()}

      {:error, reason} ->
        {:error, error(503, to_string(reason), "control-plane backend is unavailable")}
    end
  end

  @spec record_outcome(auth(), Model.t(), RoutingSelection.t(), non_neg_integer()) :: :ok
  def record_outcome(auth, model, selection, status) when status in 200..299 do
    record_result(
      "control_plane_route_success",
      selection,
      RouteLifecycle.selection_success(auth, model, selection)
    )
  end

  def record_outcome(auth, model, selection, 401) do
    record_result(
      "control_plane_route_failure",
      selection,
      RouteLifecycle.selection_failure(
        auth,
        model,
        selection,
        nil,
        "upstream_unauthorized"
      )
    )
  end

  def record_outcome(auth, model, selection, status) when status >= 500 do
    record_result(
      "control_plane_route_failure",
      selection,
      RouteLifecycle.selection_failure(auth, model, selection, nil, "upstream_5xx")
    )
  end

  def record_outcome(_auth, _model, _selection, _status), do: :ok

  @spec record_dispatch_failure(auth(), Model.t(), RoutingSelection.t(), String.t()) :: :ok
  def record_dispatch_failure(auth, model, selection, code) do
    record_result(
      "control_plane_route_dispatch_failure",
      selection,
      RouteLifecycle.selection_failure(auth, model, selection, nil, code)
    )
  end

  defp control_plane_route_model(auth) do
    case Access.normalize_api_key_policy(auth.api_key) do
      {:ok, policy} ->
        models =
          auth.pool
          |> Catalog.list_visible_models()
          |> Enum.filter(&model_visible_to_policy?(&1, policy))

        case configured_control_plane_model(auth.pool, models) do
          {:ok, %Model{} = model} -> {:ok, model}
          :default -> default_control_plane_model(auth.pool, models)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error,
         error(401, to_string(reason), "API key policy could not be evaluated", "authorization")}
    end
  end

  defp configured_control_plane_model(pool, models) do
    case configured_control_plane_model_identifier(pool) do
      nil -> :default
      identifier -> find_configured_control_plane_model(identifier, models)
    end
  end

  defp find_configured_control_plane_model(identifier, models) do
    Enum.find_value(models, {:error, control_plane_model_unavailable_error()}, fn model ->
      if identifier in [model.exposed_model_id, model.upstream_model_id], do: {:ok, model}
    end)
  end

  defp configured_control_plane_model_identifier(pool) do
    case Pools.get_routing_settings(pool) do
      %{metadata: metadata} when is_map(metadata) ->
        metadata
        |> Map.get("control_plane_model", Map.get(metadata, "control_plane_model_identifier"))
        |> clean_string()

      _settings ->
        nil
    end
  end

  defp default_control_plane_model(pool, models) do
    case models do
      [] ->
        {:error, error(400, "invalid_model", "model is not available for this pool", "model")}

      models ->
        source_assignment_ids =
          models
          |> Enum.flat_map(&source_assignment_ids/1)
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()

        {:ok,
         %Model{
           pool_id: pool.id,
           upstream_model_id: @control_plane_model_identifier,
           exposed_model_id: @control_plane_model_identifier,
           display_name: "Control plane",
           status: "active",
           supports_responses: true,
           supports_streaming: false,
           supports_tools: false,
           supports_reasoning: false,
           source_assignment_count: length(source_assignment_ids),
           metadata: %{
             "control_plane_route" => true,
             "source_assignment_ids" => source_assignment_ids
           }
         }}
    end
  end

  defp source_assignment_ids(%Model{} = model) do
    case get_in(model.metadata || %{}, ["source_assignment_ids"]) do
      ids when is_list(ids) -> ids
      _value -> []
    end
  end

  defp clean_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp clean_string(_value), do: nil

  defp control_plane_model_unavailable_error do
    error(400, "invalid_model", "control-plane model is not available for this pool", "model")
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

  defp route_filter_input(auth, model, endpoint, request_options, candidates) do
    CandidateEligibility.FilterInput.new(%{
      auth: auth,
      model: model,
      endpoint: endpoint,
      payload: %{},
      request_options: request_options,
      candidates: candidates
    })
  end

  defp record_result(operation, selection, result) do
    RouteLifecycle.log_optional_result(operation, metadata(selection), result)
  end

  defp metadata(selection) do
    [
      pool_upstream_assignment_id: selection.assignment.id,
      route_class: selection.route_class
    ]
  end

  defp no_eligible_backend_error do
    error(
      503,
      "no_eligible_backend",
      "no healthy eligible backend is currently available",
      "model"
    )
  end

  defp error(status, code, message, param \\ nil, metadata \\ %{}),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
