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
    line_or_message_usage =
      best_usage(usage_from_sse_lines(body), from_delimited_json_messages(body))

    case best_usage(line_or_message_usage, usage_from_retained_usage_fragment(body)) do
      %{status: "usage_known"} = usage -> usage
      _missing -> %{status: "usage_unknown", source: "websocket_usage_missing"}
    end
  end

  defp from_sse_body(body, missing_source) do
    best_usage(usage_from_sse_lines(body), usage_from_retained_usage_fragment(body)) ||
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
    body
    |> retained_usage_candidates()
    |> Enum.reduce(nil, fn candidate, acc ->
      case usage_from_retained_usage_candidate(candidate) do
        %{status: "usage_known"} = usage -> usage
        _missing -> acc
      end
    end)
  end

  defp retained_usage_candidates(body) do
    ~r/"usage"\s*:/
    |> Regex.scan(body, return: :index)
    |> Enum.map(fn [{offset, _length} | _captures] ->
      binary_part(body, offset, byte_size(body) - offset)
    end)
  end

  defp usage_from_retained_usage_candidate(candidate) do
    with {:ok, input_tokens} <- retained_int(candidate, ~r/"input_tokens"\s*:\s*(\d+)/),
         {:ok, output_tokens} <- retained_int(candidate, ~r/"output_tokens"\s*:\s*(\d+)/),
         {:ok, total_tokens} <- retained_int(candidate, ~r/"total_tokens"\s*:\s*(\d+)/) do
      %{
        "input_tokens" => input_tokens,
        "cached_input_tokens" => retained_cached_input_tokens(candidate),
        "output_tokens" => output_tokens,
        "reasoning_tokens" => retained_int_or_zero(candidate, ~r/"reasoning_tokens"\s*:\s*(\d+)/),
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
    Enum.reduce(lines, nil, fn line, acc ->
      case Jason.decode(line) do
        {:ok, decoded} -> latest_usage_candidate(decoded, acc)
        {:error, _reason} -> acc
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
    latest_usage(output) || maybe_default_usage(default)
  end

  defp usage_from_decoded(_decoded, default), do: maybe_default_usage(default)

  defp latest_usage(items) do
    Enum.reduce(items, nil, fn item, acc ->
      case usage_from_decoded(item, false) do
        %{status: "usage_known"} = usage -> usage
        %{status: "usage_unknown"} = usage -> acc || usage
        nil -> acc
      end
    end)
  end

  defp latest_usage_candidate(decoded, acc) do
    case usage_from_decoded(decoded, false) do
      %{status: "usage_known"} = usage -> usage
      %{status: "usage_unknown"} = usage -> acc || usage
      nil -> acc
    end
  end

  defp best_usage(nil, nil), do: nil

  defp best_usage(%{status: "usage_known"} = usage, nil), do: usage
  defp best_usage(nil, %{status: "usage_known"} = usage), do: usage

  defp best_usage(
         %{status: "usage_known"} = line_usage,
         %{status: "usage_known"} = fragment_usage
       ) do
    if total_tokens(fragment_usage) > total_tokens(line_usage),
      do: fragment_usage,
      else: line_usage
  end

  defp best_usage(%{status: "usage_unknown"}, %{status: "usage_known"} = usage), do: usage
  defp best_usage(%{status: "usage_known"} = usage, %{status: "usage_unknown"}), do: usage
  defp best_usage(%{status: "usage_unknown"} = usage, nil), do: usage
  defp best_usage(nil, %{status: "usage_unknown"} = usage), do: usage
  defp best_usage(%{status: "usage_unknown"} = usage, _fragment_usage), do: usage
  defp best_usage(_line_usage, %{status: "usage_unknown"} = usage), do: usage

  defp total_tokens(%{total_tokens: total_tokens}) when is_integer(total_tokens), do: total_tokens
  defp total_tokens(_usage), do: 0

  defp normalize_usage(usage, envelope) do
    with {:ok, input_tokens} <-
           required_int_value(usage["input_tokens"] || usage["prompt_tokens"]),
         {:ok, cached_input_tokens} <- optional_int_value(cached_input_tokens(usage)),
         {:ok, output_tokens} <-
           required_int_value(usage["output_tokens"] || usage["completion_tokens"]),
         {:ok, reasoning_tokens} <- optional_int_value(usage["reasoning_tokens"]),
         {:ok, total_tokens} <-
           total_tokens_value(usage["total_tokens"], input_tokens, output_tokens) do
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

  defp total_tokens_value(nil, input_tokens, output_tokens),
    do: {:ok, input_tokens + output_tokens}

  defp total_tokens_value(value, _input_tokens, _output_tokens), do: required_int_value(value)

  defp required_int_value(nil), do: :error
  defp required_int_value(value), do: int_value(value)

  defp optional_int_value(nil), do: {:ok, 0}
  defp optional_int_value(value), do: int_value(value)

  defp int_value(nil), do: :error
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
