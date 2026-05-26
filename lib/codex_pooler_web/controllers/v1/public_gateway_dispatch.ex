defmodule CodexPoolerWeb.V1.PublicGatewayDispatch do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Service
  alias CodexPoolerWeb.Runtime.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.V1.PublicGatewayResult

  @type auth :: CodexPooler.Access.auth_context()
  @type conn :: Plug.Conn.t()
  @type gateway_call_result ::
          {:ok, Contracts.gateway_result()} | {:error, Contracts.gateway_error()}
  @type coercer :: (-> {:ok, map()} | {:error, Contracts.gateway_error()})
  @type success_normalizer :: (map(), map() -> map())

  @spec authenticated(conn(), String.t(), String.t(), (auth() -> gateway_call_result())) :: conn()
  def authenticated(conn, route_class, endpoint, fun)
      when is_binary(route_class) and is_binary(endpoint) and is_function(fun, 1) do
    case GatewayHelpers.authenticate_v1(conn) do
      {:ok, auth} ->
        result =
          GatewayHelpers.admit(conn, route_class, %{endpoint: endpoint}, fn ->
            fun.(auth)
          end)

        GatewayHelpers.send_or_error(conn, result)

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  @spec coerced(conn(), coercer(), success_normalizer()) :: conn()
  def coerced(conn, coercer, normalize_success)
      when is_function(coercer, 0) and is_function(normalize_success, 2) do
    case GatewayHelpers.authenticate_v1(conn) do
      {:ok, auth} ->
        case coercer.() do
          {:ok, coerced} ->
            result = execute_coerced_service(conn, auth, coerced)
            PublicGatewayResult.send(conn, result, &normalize_success.(&1, coerced))

          {:error, reason} ->
            GatewayHelpers.send_error(conn, reason)
        end

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  defp execute_coerced_service(conn, auth, %{
         endpoint: endpoint,
         payload: payload,
         request_options: %RequestOptions{} = request_options
       }) do
    request_options =
      RequestOptions.mark_openai_compatibility_origin(
        request_options,
        conn.request_path,
        endpoint
      )

    route_class = RequestOptions.route_class(request_options)

    GatewayHelpers.admit(conn, route_class, %{endpoint: endpoint}, fn ->
      Service.execute(auth, endpoint, payload, request_options)
    end)
  end
end
