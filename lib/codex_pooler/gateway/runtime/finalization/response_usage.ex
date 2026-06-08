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
    case usage_from_sse_lines(body) do
      %{status: "usage_known"} = usage ->
        usage

      _missing ->
        from_delimited_json_messages(body) ||
          usage_from_retained_usage_fragment(body) ||
          %{status: "usage_unknown", source: "websocket_usage_missing"}
    end
  end

  defp from_sse_body(body, missing_source) do
    usage_from_sse_lines(body) || usage_from_retained_usage_fragment(body) ||
      %{status: "usage_unknown", source: missing_source}
  end

  defp usage_from_sse_lines(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "[DONE]"))
    |> usage_from_json_lines()
  end

  defp usage_from_retained_usage_fragment(body) do
    with {:ok, input_tokens} <- retained_int(body, ~r/"input_tokens"\s*:\s*(\d+)/),
         {:ok, output_tokens} <- retained_int(body, ~r/"output_tokens"\s*:\s*(\d+)/),
         {:ok, total_tokens} <- retained_int(body, ~r/"total_tokens"\s*:\s*(\d+)/) do
      %{
        "input_tokens" => input_tokens,
        "cached_input_tokens" => retained_cached_input_tokens(body),
        "output_tokens" => output_tokens,
        "reasoning_tokens" => retained_int_or_zero(body, ~r/"reasoning_tokens"\s*:\s*(\d+)/),
        "total_tokens" => total_tokens
      }
      |> normalize_usage(%{})
    else
      :error -> nil
    end
  end

  defp retained_cached_input_tokens(body) do
    case retained_int(body, ~r/"cached_input_tokens"\s*:\s*(\d+)/) do
      {:ok, tokens} -> tokens
      :error -> retained_int_or_zero(body, ~r/"cached_tokens"\s*:\s*(\d+)/)
    end
  end

  defp retained_int_or_zero(body, pattern) do
    case retained_int(body, pattern) do
      {:ok, value} -> value
      :error -> 0
    end
  end

  defp retained_int(body, pattern) do
    case Regex.run(pattern, body, capture: :all_but_first) do
      [value] -> int_value(value)
      _other -> :error
    end
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
