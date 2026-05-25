defmodule CodexPooler.Gateway.Runtime.Finalization.ResponseUsage do
  @moduledoc """
  Extracts accounting usage metadata from upstream JSON, SSE, and websocket response bodies.
  """

  @type usage :: %{
          required(:status) => String.t(),
          required(:source) => String.t(),
          optional(:input_tokens) => non_neg_integer(),
          optional(:cached_input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:reasoning_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer(),
          optional(:service_tier) => String.t() | nil
        }

  @spec from_json(binary()) :: usage()
  def from_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> usage_from_decoded(decoded)
      {:error, _reason} -> %{status: "usage_unknown", source: "json_decode_failed"}
    end
  end

  @spec from_sse(binary()) :: usage()
  def from_sse(body) when is_binary(body), do: from_sse_body(body, "sse_usage_missing")

  @spec from_websocket_body(binary()) :: usage()
  def from_websocket_body(body) when is_binary(body) do
    case from_sse_body(body, "websocket_usage_missing") do
      %{status: "usage_known"} = usage ->
        usage

      %{status: "usage_unknown"} ->
        from_delimited_json_messages(body) ||
          %{status: "usage_unknown", source: "websocket_usage_missing"}
    end
  end

  defp from_sse_body(body, missing_source) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "[DONE]"))
    |> usage_from_json_lines()
    |> Kernel.||(%{status: "usage_unknown", source: missing_source})
  end

  defp from_delimited_json_messages(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> usage_from_json_lines()
  end

  defp usage_from_json_lines(lines) do
    Enum.find_value(lines, fn line ->
      case Jason.decode(line) do
        {:ok, decoded} -> usage_from_decoded(decoded, false)
        {:error, _reason} -> nil
      end
    end)
  end

  defp usage_from_decoded(decoded, default \\ true)

  defp usage_from_decoded(%{"usage" => usage} = decoded, _default) when is_map(usage),
    do: normalize_usage(usage, decoded)

  defp usage_from_decoded(%{"response" => %{"usage" => usage} = response}, _default)
       when is_map(usage),
       do: normalize_usage(usage, response)

  defp usage_from_decoded(%{"output" => output}, default) when is_list(output) do
    Enum.find_value(output, &usage_from_decoded(&1, false)) || maybe_default_usage(default)
  end

  defp usage_from_decoded(_decoded, default), do: maybe_default_usage(default)

  defp normalize_usage(usage, envelope) do
    with {:ok, input_tokens} <- int_value(usage["input_tokens"] || usage["prompt_tokens"]),
         {:ok, cached_input_tokens} <- int_value(cached_input_tokens(usage)),
         {:ok, output_tokens} <- int_value(usage["output_tokens"] || usage["completion_tokens"]),
         {:ok, reasoning_tokens} <- int_value(usage["reasoning_tokens"]),
         {:ok, total_tokens} <- int_value(usage["total_tokens"]) do
      %{
        status: "usage_known",
        source: "upstream_usage",
        input_tokens: input_tokens,
        cached_input_tokens: cached_input_tokens,
        output_tokens: output_tokens,
        reasoning_tokens: reasoning_tokens,
        total_tokens: total_tokens,
        service_tier: service_tier(envelope)
      }
    else
      :error -> %{status: "usage_unknown", source: "invalid_usage_tokens"}
    end
  end

  defp service_tier(%{"service_tier" => tier}) when is_binary(tier), do: tier
  defp service_tier(%{"response" => %{"service_tier" => tier}}) when is_binary(tier), do: tier
  defp service_tier(_envelope), do: nil

  defp cached_input_tokens(%{"cached_input_tokens" => tokens}), do: tokens

  defp cached_input_tokens(%{"input_tokens_details" => %{"cached_tokens" => tokens}}),
    do: tokens

  defp cached_input_tokens(%{"prompt_tokens_details" => %{"cached_tokens" => tokens}}),
    do: tokens

  defp cached_input_tokens(_usage), do: nil

  defp maybe_default_usage(true), do: %{status: "usage_unknown", source: "usage_missing"}
  defp maybe_default_usage(false), do: nil

  defp int_value(nil), do: {:ok, 0}
  defp int_value(value) when is_integer(value), do: {:ok, value}
  defp int_value(value) when is_float(value), do: :error

  defp int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _other -> :error
    end
  end

  defp int_value(_value), do: :error
end
