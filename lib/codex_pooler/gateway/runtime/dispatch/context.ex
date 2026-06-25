defmodule CodexPooler.Gateway.Runtime.Dispatch.Context do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.BridgeRing
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState

  defstruct [
    :auth,
    :endpoint,
    :payload,
    :model,
    :reserved,
    :candidates,
    :request_options,
    :route_state,
    :route_plan,
    :route_class
  ]

  @type t :: %__MODULE__{
          auth: CodexPooler.Access.auth_context(),
          endpoint: String.t(),
          payload: map(),
          model: Model.t(),
          reserved: Accounting.request_result_row(),
          candidates: [BridgeRing.candidate()],
          request_options: RequestOptions.t(),
          route_state: RouteState.t(),
          route_plan: BridgeRing.route_plan(),
          route_class: String.t()
        }
end
