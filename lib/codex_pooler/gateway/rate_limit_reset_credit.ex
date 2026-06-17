defmodule CodexPooler.Gateway.RateLimitResetCredit do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.ControlPlaneProxy

  @operation "rate_limit_reset_credit_consume"

  @type auth :: Access.auth_context()
  @type gateway_error :: Contracts.gateway_error()

  @spec consume(auth(), String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, gateway_error()}
  def consume(auth, local_endpoint, upstream_endpoint, redeem_request_id, request_opts)
      when is_binary(local_endpoint) and is_binary(upstream_endpoint) and
             is_binary(redeem_request_id) and is_map(request_opts) do
    request =
      ControlPlaneProxy.build_request!(%{
        local_endpoint: local_endpoint,
        accounting_endpoint: accounting_endpoint(local_endpoint),
        upstream_endpoint: upstream_endpoint,
        method: "POST",
        body: Jason.encode!(%{"redeem_request_id" => redeem_request_id}),
        body_mode: {:json, :object},
        request_headers: [],
        request_opts: request_opts,
        operation: @operation
      })

    ControlPlaneProxy.execute(auth, request)
  end

  defp accounting_endpoint("/wham/rate-limit-reset-credits/consume"), do: "/wham/usage"

  defp accounting_endpoint("/backend-api/wham/rate-limit-reset-credits/consume"),
    do: "/backend-api/wham/usage"

  defp accounting_endpoint(_local_endpoint), do: "/api/codex/usage"
end
