defmodule CodexPoolerWeb.Runtime.ControlPlaneJson do
  @moduledoc false

  @type json_body_mode :: {:json, :object | :object_or_array}

  @spec read_body(Plug.Conn.t(), json_body_mode()) ::
          {:ok, binary(), Plug.Conn.t()} | {:error, map()}

  def read_body(%Plug.Conn{method: method} = conn, _route) when method in ["GET", "HEAD"] do
    {:ok, "", conn}
  end

  def read_body(%Plug.Conn{private: %{runtime_json_parse_error: true}}, {:json, _contract}) do
    {:error, %{status: 400, code: "invalid_request", message: "request body must be valid JSON"}}
  end

  def read_body(%Plug.Conn{} = conn, {:json, contract})
      when contract in [:object, :object_or_array] do
    if json_content_type?(conn) do
      read_json_body(conn, contract)
    else
      {:error, %{status: 400, code: "invalid_request", message: "request body must be JSON"}}
    end
  end

  defp read_json_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = _conn, _route) do
    {:error, %{status: 400, code: "invalid_request", message: "request body must be JSON"}}
  end

  defp read_json_body(%Plug.Conn{body_params: params} = conn, :object_or_array)
       when is_map(params) or is_list(params) do
    {:ok, Jason.encode!(root_json_value(params)), conn}
  end

  defp read_json_body(%Plug.Conn{body_params: params} = conn, :object) when is_map(params) do
    if root_json_array_wrapper?(params) do
      {:error,
       %{status: 400, code: "invalid_request", message: "request body must be a JSON object"}}
    else
      {:ok, Jason.encode!(params), conn}
    end
  end

  defp read_json_body(%Plug.Conn{}, :object_or_array) do
    {:error,
     %{
       status: 400,
       code: "invalid_request",
       message: "request body must be a JSON object or array"
     }}
  end

  defp json_content_type?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> List.first()
    |> case do
      nil ->
        false

      content_type ->
        content_type = String.downcase(content_type)

        String.starts_with?(content_type, "application/json") or
          String.contains?(content_type, "+json")
    end
  end

  defp root_json_value(%{"_json" => value} = params) when map_size(params) == 1, do: value
  defp root_json_value(params), do: params

  defp root_json_array_wrapper?(%{"_json" => value} = params)
       when map_size(params) == 1 and is_list(value),
       do: true

  defp root_json_array_wrapper?(_params), do: false
end
