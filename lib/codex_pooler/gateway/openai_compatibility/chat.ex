defmodule CodexPooler.Gateway.OpenAICompatibility.Chat do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.{Error, Responses, Validation}
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @spec validate(term()) :: {:ok, map()} | {:error, Error.reason()}
  def validate(payload) do
    with {:ok, %{chat_payload: chat_payload, response_payload: response_payload}} <-
           prepare_response_payload(payload),
         {:ok, _response_payload} <- Responses.validate(response_payload) do
      {:ok, chat_payload}
    end
  end

  @spec coerce(term(), map() | keyword()) ::
          {:ok,
           %{
             endpoint: String.t(),
             payload: map(),
             request_options: RequestOptions.t(),
             chat_payload: map()
           }}
          | {:error, Error.reason()}
  def coerce(payload, opts \\ %{}) do
    with {:ok, %{chat_payload: chat_payload, response_payload: response_payload}} <-
           prepare_response_payload(payload),
         {:ok, response} <- Responses.coerce(response_payload, opts) do
      {:ok, Map.put(response, :chat_payload, chat_payload)}
    end
  end

  defp prepare_response_payload(payload) do
    with {:ok, payload} <- Validation.normalize_payload(payload),
         :ok <- reject_legacy_functions(payload),
         :ok <- Validation.reject_high_impact_fields(payload),
         :ok <- Validation.reject_unsupported_fields(payload, :chat),
         :ok <- Validation.require_model(payload),
         {:ok, messages} <- messages(payload),
         {:ok, response_payload} <- response_payload(payload, messages) do
      {:ok, %{chat_payload: payload, response_payload: response_payload}}
    end
  end

  defp reject_legacy_functions(payload) do
    cond do
      Map.has_key?(payload, "functions") ->
        {:error, Error.invalid_request("legacy functions are not translatable", "functions")}

      Map.has_key?(payload, "function_call") ->
        {:error,
         Error.invalid_request("legacy function_call is not translatable", "function_call")}

      true ->
        :ok
    end
  end

  defp messages(%{"messages" => messages}) when is_list(messages) and messages != [] do
    if Enum.all?(messages, &valid_message?/1) do
      {:ok, messages}
    else
      {:error, Error.invalid_request("messages must contain role/content objects", "messages")}
    end
  end

  defp messages(%{"messages" => _messages}),
    do: {:error, Error.invalid_request("messages must be a non-empty array", "messages")}

  defp messages(_payload), do: {:error, Error.invalid_request("messages is required", "messages")}

  defp valid_message?(%{"role" => role, "content" => content})
       when role in ["system", "user", "assistant", "developer", "tool"] do
    valid_content?(content)
  end

  defp valid_message?(_message), do: false

  defp response_payload(payload, messages) do
    base = %{
      "model" => payload["model"],
      "input" => Enum.map(messages, &message_to_input_item/1)
    }

    payload =
      base
      |> maybe_put(payload, "tools")
      |> maybe_put(payload, "tool_choice")
      |> maybe_put(payload, "stream")
      |> put_text_format(payload)

    {:ok, payload}
  end

  defp message_to_input_item(%{"role" => role, "content" => content} = message) do
    %{"type" => "message", "role" => role, "content" => normalize_content(content)}
    |> maybe_put(message, "name")
    |> maybe_put(message, "tool_call_id")
  end

  defp normalize_content(content) when is_binary(content) do
    [%{"type" => "input_text", "text" => content}]
  end

  defp normalize_content(content) when is_list(content),
    do: Enum.map(content, &normalize_content_part/1)

  defp normalize_content(%{} = content), do: [normalize_content_part(content)]

  defp normalize_content(content), do: content

  defp normalize_content_part(%{"type" => "text", "text" => text}),
    do: %{"type" => "input_text", "text" => text}

  defp normalize_content_part(%{"type" => "image_url", "image_url" => image_url})
       when is_binary(image_url),
       do: %{"type" => "input_image", "image_url" => image_url}

  defp normalize_content_part(%{"type" => "image_url", "image_url" => %{"url" => image_url}})
       when is_binary(image_url),
       do: %{"type" => "input_image", "image_url" => image_url}

  defp normalize_content_part(%{} = part), do: part

  defp valid_content?(content) when is_binary(content), do: true

  defp valid_content?(content) when is_list(content),
    do: content != [] and Enum.all?(content, &valid_content_part?/1)

  defp valid_content?(%{} = content), do: valid_content_part?(content)
  defp valid_content?(_content), do: false

  defp valid_content_part?(%{"type" => type, "text" => text})
       when type in ["text", "input_text"] and is_binary(text),
       do: true

  defp valid_content_part?(%{"type" => "image_url", "image_url" => image_url})
       when is_binary(image_url),
       do: true

  defp valid_content_part?(%{"type" => "image_url", "image_url" => %{"url" => image_url}})
       when is_binary(image_url),
       do: true

  defp valid_content_part?(%{"type" => "input_image", "image_url" => image_url})
       when is_binary(image_url),
       do: true

  defp valid_content_part?(_part), do: false

  defp put_text_format(acc, %{"response_format" => response_format}) do
    case response_format do
      %{"type" => "json_object"} ->
        Map.put(acc, "text", %{"format" => %{"type" => "json_object"}})

      %{"type" => "json_schema", "json_schema" => schema} ->
        Map.put(acc, "text", %{"format" => Map.put(schema, "type", "json_schema")})

      %{"type" => "text"} ->
        Map.put(acc, "text", %{"format" => %{"type" => "text"}})

      _format ->
        Map.put(acc, "response_format", response_format)
    end
  end

  defp put_text_format(acc, _payload), do: acc

  defp maybe_put(acc, source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(acc, key, value)
      :error -> acc
    end
  end
end
