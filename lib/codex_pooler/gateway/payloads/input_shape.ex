defmodule CodexPooler.Gateway.Payloads.InputShape do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @unsupported_input_image_message "backend-api/files uploads are not valid Responses input_image.file_id references, and Codex sediment:// file URIs are unsupported as Responses input_image.image_url values"

  @spec validate(term()) :: :ok | {:error, Error.reason()}
  def validate(payload) when is_map(payload) do
    case find_unsupported_input_image(payload) do
      nil -> :ok
      :unsupported_input_image_format -> {:error, unsupported_input_image_error()}
    end
  end

  def validate(_payload), do: :ok

  defp find_unsupported_input_image(%{} = value) do
    value = Map.new(value, fn {key, item_value} -> {to_string(key), item_value} end)

    cond do
      unsupported_input_image_file_id?(value) ->
        :unsupported_input_image_format

      unsupported_input_image_url?(value) ->
        :unsupported_input_image_format

      true ->
        Enum.find_value(Map.values(value), &find_unsupported_input_image/1)
    end
  end

  defp find_unsupported_input_image(values) when is_list(values) do
    Enum.find_value(values, &find_unsupported_input_image/1)
  end

  defp find_unsupported_input_image(_value), do: nil

  defp unsupported_input_image_file_id?(%{"type" => "input_image"} = value) do
    Map.has_key?(value, "file_id")
  end

  defp unsupported_input_image_file_id?(_value), do: false

  defp unsupported_input_image_url?(%{"type" => "input_image", "image_url" => image_url})
       when is_binary(image_url) do
    image_url
    |> String.trim()
    |> String.starts_with?("sediment://")
  end

  defp unsupported_input_image_url?(_value), do: false

  defp unsupported_input_image_error do
    %{
      status: 400,
      code: "unsupported_input_image_format",
      message: @unsupported_input_image_message,
      param: "input"
    }
  end
end
