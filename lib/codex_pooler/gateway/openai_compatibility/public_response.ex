defmodule CodexPooler.Gateway.OpenAICompatibility.PublicResponse do
  @moduledoc false

  @type success_normalizer :: (map() -> map())

  @spec stream_headers([{term(), term()}]) :: [{String.t(), String.t()} | {term(), term()}]
  def stream_headers(headers) do
    headers
    |> Enum.reject(fn {key, _value} -> String.downcase(to_string(key)) == "content-type" end)
    |> Kernel.++([{"content-type", "text/event-stream"}])
  end

  @spec normalize_raw_body(pos_integer(), term(), success_normalizer()) ::
          {:ok, map()} | :passthrough
  def normalize_raw_body(status, body, normalize_success) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) and status < 400 ->
        {:ok, normalize_success.(decoded)}

      {:ok, %{"error" => %{} = error}} when status >= 400 ->
        {:ok, %{"error" => normalize_error(error)}}

      {:ok, decoded} when is_map(decoded) and status >= 400 ->
        {:ok, normalize_error_body(status)}

      _error ->
        if status >= 400, do: {:ok, normalize_error_body(status)}, else: :passthrough
    end
  end

  def normalize_raw_body(status, _body, _normalize_success) do
    if status >= 400, do: {:ok, normalize_error_body(status)}, else: :passthrough
  end

  defp normalize_error(error) do
    %{
      "message" => safe_error_message(error),
      "type" => Map.get(error, "type") || "invalid_request_error",
      "code" => Map.get(error, "code") || "upstream_error",
      "param" => Map.get(error, "param")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_error_body(status) do
    %{
      "error" =>
        normalize_error(%{
          "message" => "upstream returned #{status}",
          "code" => "upstream_status"
        })
    }
  end

  defp safe_error_message(%{"message" => message}) when is_binary(message), do: message
  defp safe_error_message(_error), do: "upstream request failed"
end
