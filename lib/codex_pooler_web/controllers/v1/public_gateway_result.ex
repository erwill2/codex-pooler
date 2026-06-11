defmodule CodexPoolerWeb.V1.PublicGatewayResult do
  @moduledoc false

  alias CodexPoolerWeb.Runtime.PublicGatewayResult, as: RuntimePublicGatewayResult

  @type success_normalizer :: RuntimePublicGatewayResult.success_normalizer()
  @type gateway_call_result :: RuntimePublicGatewayResult.gateway_call_result()

  @spec send(Plug.Conn.t(), gateway_call_result(), success_normalizer()) :: Plug.Conn.t()
  defdelegate send(conn, result, success_normalizer), to: RuntimePublicGatewayResult
end
