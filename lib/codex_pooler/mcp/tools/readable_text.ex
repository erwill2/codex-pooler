defmodule CodexPooler.MCP.Tools.ReadableText do
  @moduledoc """
  Formats bounded, human-readable MCP text from already-sanitized map rows.

  This module is presentation-only. Callers must pass explicit presenter maps that
  have already gone through the domain MCP sanitization/privacy layer. The
  formatter rejects structs and applies a final defensive cleanup to scalar text
  fragments so text-only MCP clients do not display unsafe raw values.
  """

  alias CodexPooler.MCP.Redaction

  @max_visible_rows 10
  @max_value_length 120

  @type field_name :: atom() | String.t()
  @type field_spec ::
          field_name() | {field_name(), String.t()} | {field_name(), String.t(), keyword()}

  @spec list(String.t(), [map()], [field_spec()], keyword()) :: String.t()
  def list(domain_label, rows, fields, opts \\ [])
      when is_binary(domain_label) and is_list(rows) and is_list(fields) and is_list(opts) do
    rows = validate_rows!(rows)

    if rows == [] do
      empty(domain_label)
    else
      rows
      |> visible_count()
      |> first_line(domain_label, opts)
      |> append_rows(rows, fields)
    end
  end

  @spec empty(String.t()) :: String.t()
  def empty(domain_label) when is_binary(domain_label) do
    "No #{domain_label} matched the visible scope"
  end

  @spec detail(String.t(), map(), [field_spec()], keyword()) :: String.t()
  def detail(domain_label, row, fields, opts \\ [])
      when is_binary(domain_label) and is_map(row) and is_list(fields) and is_list(opts) do
    [row] = validate_rows!([row])

    first_line(1, domain_label, opts)
    |> append_rows([row], fields)
  end

  @spec not_found(String.t()) :: String.t()
  def not_found(domain_label) when is_binary(domain_label) do
    "No visible #{domain_label} matched the selector"
  end

  @spec ambiguous(String.t(), [map()], [field_spec()]) :: String.t()
  def ambiguous(domain_label, candidates, fields)
      when is_binary(domain_label) and is_list(candidates) and is_list(fields) do
    candidates = validate_rows!(candidates)
    count = length(candidates)

    "#{count} visible #{domain_label} candidates matched the selector"
    |> append_rows(candidates, fields)
  end

  @spec scalar(term(), keyword()) :: String.t() | nil
  def scalar(value, opts \\ []) when is_list(opts) do
    required? = Keyword.get(opts, :required, false)

    value
    |> scalar_text()
    |> normalize_scalar(required?)
  end

  defp visible_count(rows), do: rows |> length() |> min(@max_visible_rows)

  defp first_line(shown_count, domain_label, opts) do
    ["#{shown_count} #{domain_label} returned", total_text(opts), offset_text(opts)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp total_text(opts) do
    case Keyword.get(opts, :total) do
      total when is_integer(total) -> "total #{total}"
      _other -> nil
    end
  end

  defp offset_text(opts) do
    case Keyword.get(opts, :offset) do
      offset when is_integer(offset) -> "offset #{offset}"
      _other -> nil
    end
  end

  defp append_rows(first_line, rows, fields) do
    visible_rows = Enum.take(rows, @max_visible_rows)
    omitted_count = length(rows) - length(visible_rows)

    lines =
      [first_line] ++
        Enum.map(visible_rows, &row_line(&1, fields)) ++
        omission_lines(omitted_count)

    Enum.join(lines, "\n")
  end

  defp omission_lines(omitted_count) when omitted_count > 0 do
    [
      "- ... #{omitted_count} more rows omitted from text; use structuredContent or refine filters"
    ]
  end

  defp omission_lines(_omitted_count), do: []

  defp row_line(row, fields) do
    fragments =
      fields
      |> Enum.map(&field_fragment(row, &1))
      |> Enum.reject(&is_nil/1)

    "- " <> Enum.join(fragments, " ")
  end

  defp field_fragment(row, field_spec) do
    {field, label, opts} = normalize_field_spec(field_spec)
    value = Map.get(row, to_string(field), Map.get(row, field))

    case scalar(value, opts) do
      nil -> nil
      text -> "#{label}=#{text}"
    end
  end

  defp normalize_field_spec({field, label, opts}) when is_list(opts) do
    {field, label, opts}
  end

  defp normalize_field_spec({field, label}) do
    {field, label, []}
  end

  defp normalize_field_spec(field) do
    {field, to_string(field), []}
  end

  defp validate_rows!(rows) do
    Enum.map(rows, fn
      %{__struct__: struct} ->
        raise ArgumentError,
              "MCP readable text rows must be sanitized maps, got raw struct #{inspect(struct)}"

      row when is_map(row) ->
        reject_struct_values!(row)
        row

      row ->
        raise ArgumentError,
              "MCP readable text rows must be sanitized maps, got #{inspect(row)}"
    end)
  end

  defp reject_struct_values!(%{__struct__: struct}) do
    raise ArgumentError,
          "MCP readable text rows must be sanitized maps, got raw struct #{inspect(struct)}"
  end

  defp reject_struct_values!(map) when is_map(map) do
    Enum.each(map, fn {_key, value} -> reject_struct_values!(value) end)
  end

  defp reject_struct_values!(list) when is_list(list),
    do: Enum.each(list, &reject_struct_values!/1)

  defp reject_struct_values!(_value), do: :ok

  defp scalar_text(nil), do: nil
  defp scalar_text(value) when is_binary(value), do: value
  defp scalar_text(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar_text(value) when is_float(value), do: Float.to_string(value)
  defp scalar_text(value) when is_boolean(value), do: Atom.to_string(value)
  defp scalar_text(value) when is_atom(value), do: Atom.to_string(value)

  defp scalar_text(value) do
    raise ArgumentError,
          "MCP readable text scalar values must already be sanitized scalars, got #{inspect(value)}"
  end

  defp normalize_scalar(nil, true), do: "unknown"
  defp normalize_scalar(nil, false), do: nil

  defp normalize_scalar(value, required?) do
    value =
      value
      |> String.replace(~r/[[:cntrl:]]+/, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      value == "" and required? ->
        "unknown"

      value == "" ->
        nil

      unsafe_scalar?(value) ->
        "[REDACTED]"

      true ->
        String.slice(value, 0, @max_value_length)
    end
  end

  defp unsafe_scalar?(value) do
    forbidden_sentinel?(value) or raw_email?(value) or raw_ip?(value) or raw_url?(value) or
      bearer_or_key?(value)
  end

  defp forbidden_sentinel?(value) do
    Enum.any?(Redaction.forbidden_sentinels(), fn {_category, sentinel} ->
      String.contains?(value, sentinel)
    end)
  end

  defp raw_email?(value),
    do: Regex.match?(~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/, value)

  defp raw_ip?(value), do: Regex.match?(~r/^\d{1,3}(?:\.\d{1,3}){3}$/, value)

  defp raw_url?(value),
    do: String.starts_with?(value, "http://") or String.starts_with?(value, "https://")

  defp bearer_or_key?(value) do
    Regex.match?(~r/\bBearer\s+[A-Za-z0-9._~+\/-]+=*\b/i, value) or
      Regex.match?(~r/\b(?:sk|pk|rk|mcp|pool)_[A-Za-z0-9][A-Za-z0-9._-]{12,}\b/i, value) or
      Regex.match?(~r/\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/, value)
  end
end
