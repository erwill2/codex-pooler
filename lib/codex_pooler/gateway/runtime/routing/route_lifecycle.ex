defmodule CodexPooler.Gateway.Runtime.Routing.RouteLifecycle do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Routing.BridgeRing
  alias CodexPooler.Gateway.Routing.RouteLifecycle, as: RoutingRouteLifecycle
  alias CodexPooler.Gateway.Routing.RoutingSelection
  alias CodexPooler.Gateway.Runtime.Dispatch.Context, as: DispatchContext

  @type gateway_error :: Contracts.gateway_error()
  @type success_result :: :ok | {:error, gateway_error()}

  @spec success(DispatchContext.t()) :: success_result()
  def success(%DispatchContext{} = context) do
    RoutingRouteLifecycle.selection_success(
      context.auth,
      context.model,
      routing_selection(context)
    )
  end

  @spec failure(DispatchContext.t(), term()) :: {:ok, term()} | {:error, map()}
  def failure(%DispatchContext{} = context, code) do
    case RoutingRouteLifecycle.selection_failure(
           context.auth,
           context.model,
           routing_selection(context),
           context.reserved.request.id,
           code
         ) do
      {:ok, demotion_reason} ->
        merge_failure_metadata(context, demotion_reason)

      {:error, _gateway_error} = error ->
        error
    end
  end

  defp merge_failure_metadata(%DispatchContext{} = context, demotion_reason) do
    case Accounting.merge_request_metadata(
           context.reserved.request,
           BridgeRing.demotion_metadata(demotion_reason)
         ) do
      {:ok, _request} ->
        {:ok, demotion_reason}

      {:error, reason} ->
        FailureResponse.accounting_failure(
          :merge_route_failure_metadata,
          context.reserved.request,
          context.attempt,
          reason
        )
    end
  end

  defp routing_selection(%DispatchContext{} = context) do
    %RoutingSelection{
      assignment: context.assignment,
      identity: context.identity,
      index: context.index,
      route_plan: context.route_plan,
      route_class: context.route_class,
      selected_metadata: %{},
      attempt_metadata: context.routing_attempt_metadata,
      route_metadata: %{},
      circuit_state: context.routing_circuit_state
    }
  end
end
