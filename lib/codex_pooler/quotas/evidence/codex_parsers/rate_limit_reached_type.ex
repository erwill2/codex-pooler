defmodule CodexPooler.Quotas.Evidence.CodexParsers.RateLimitReachedType do
  @moduledoc false

  @known_types ~w(
    rate_limit_reached
    workspace_owner_credits_depleted
    workspace_member_credits_depleted
    workspace_owner_usage_limit_reached
    workspace_member_usage_limit_reached
  )

  @spec parse(term()) :: String.t() | nil
  def parse(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    if value in @known_types, do: value
  end

  def parse(_value), do: nil

  @spec parse_header([{String.t(), String.t() | [String.t()]}] | map() | term()) ::
          String.t() | nil
  def parse_header(headers) do
    headers
    |> normalize_headers()
    |> Map.get("x-codex-rate-limit-reached-type")
    |> parse()
  end

  defp normalize_headers(headers) when is_list(headers) do
    Map.new(headers, fn
      {name, values} ->
        value = if is_list(values), do: List.first(values), else: values
        {String.downcase(to_string(name)), value}
    end)
  end

  defp normalize_headers(%{} = headers), do: headers |> Map.to_list() |> normalize_headers()
  defp normalize_headers(_headers), do: %{}
end
