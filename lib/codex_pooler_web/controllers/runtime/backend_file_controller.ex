defmodule CodexPoolerWeb.Runtime.BackendFileController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Files
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.Runtime.GatewayControllerHelpers, as: GatewayHelpers

  def create(conn, _params) do
    with_authenticated_file_admission(conn, "/backend-api/files", fn auth ->
      create_authenticated(conn, auth)
    end)
  end

  def uploaded(conn, %{"file_id" => file_id}) do
    with_authenticated_file_admission(conn, "/backend-api/files/uploaded", fn auth ->
      with {:ok, result} <-
             Gateway.mark_uploaded(
               auth,
               file_id,
               request_options(conn, "/backend-api/files/uploaded", %{})
             ) do
        {:ok,
         %{
           status: 200,
           headers: [],
           body: Map.get(result, :body) || Files.response_shape(result.file)
         }}
      end
    end)
  end

  defp with_authenticated_file_admission(conn, endpoint, fun) when is_function(fun, 1) do
    case GatewayHelpers.authenticate(conn) do
      {:ok, auth} ->
        result =
          GatewayHelpers.admit(conn, RouteClass.file_upload(), %{endpoint: endpoint}, fn ->
            fun.(auth)
          end)

        GatewayHelpers.send_or_error(conn, result)

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  defp create_authenticated(conn, auth) do
    with :ok <- reject_multipart_create(conn),
         :ok <- require_json_content_type(conn),
         {:ok, payload} <- GatewayHelpers.read_json_body(conn),
         {:ok, %{body: body}} <-
           Gateway.create_upstream_file(
             auth,
             payload,
             request_options(conn, "/backend-api/files", payload)
           ) do
      {:ok, %{status: 200, headers: [], body: body}}
    end
  end

  defp request_options(conn, endpoint, payload) do
    conn
    |> GatewayHelpers.request_opts()
    |> RequestOptions.from_conn_metadata(endpoint, payload)
  end

  defp reject_multipart_create(conn) do
    if multipart_content_type?(conn) do
      {:error,
       %{
         status: 400,
         code: "unsupported_multipart_file_create",
         message: "multipart file create is not supported on this route"
       }}
    else
      :ok
    end
  end

  defp require_json_content_type(conn) do
    if json_content_type?(conn) do
      :ok
    else
      {:error,
       %{
         status: 400,
         code: "invalid_request",
         message: "request body must be a JSON object"
       }}
    end
  end

  defp json_content_type?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> List.first()
    |> case do
      nil -> false
      content_type -> content_type |> String.downcase() |> String.starts_with?("application/json")
    end
  end

  defp multipart_content_type?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> List.first()
    |> case do
      nil ->
        false

      content_type ->
        content_type |> String.downcase() |> String.starts_with?("multipart/form-data")
    end
  end
end
