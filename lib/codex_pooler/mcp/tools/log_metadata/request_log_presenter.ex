defmodule CodexPooler.MCP.Tools.LogMetadata.RequestLogPresenter do
  @moduledoc false

  alias CodexPooler.MCP.{MetadataSanitizer, PrivacyMatrix}
  alias CodexPooler.MCP.Tools.ReadableText

  @spec item(map()) :: map()
  def item(log) do
    projected =
      PrivacyMatrix.project!(:request_logs, %{
        id: log.id,
        pool_id: log.pool_id,
        pool_name: log.pool_name,
        pool_slug: log.pool_slug,
        api_key_id: log.api_key_id,
        api_key_display_name: log.api_key_display_name,
        api_key_prefix: log.api_key_prefix,
        requested_model: log.requested_model,
        transport: log.transport,
        status: log.status,
        usage_status: log.usage_status,
        correlation_id: log.correlation_id,
        response_status_code: log.response_status_code,
        retry_count: log.retry_count,
        denial_reason: log.denial_reason,
        latency_ms: log.latency_ms,
        token_counts: MetadataSanitizer.safe_value(log.token_counts),
        cost: MetadataSanitizer.safe_value(log.cost),
        errors: MetadataSanitizer.safe_value(log.errors),
        admitted_at: iso8601(log.admitted_at),
        completed_at: iso8601(log.completed_at),
        upstream_account_label: log.upstream_account_label,
        upstream_account_email: log.upstream_account_email,
        upstream_account_plan_label: log.upstream_account_plan_label,
        upstream_account_plan_family: log.upstream_account_plan_family,
        upstream_identity_id: log.upstream_identity_id,
        upstream_identity_label: log.upstream_identity_label,
        pool_upstream_assignment_id: log.pool_upstream_assignment_id,
        assignment_label: log.assignment_label,
        reasoning_effort: log.reasoning_effort,
        service_tier: log.service_tier,
        requested_service_tier: log.requested_service_tier,
        actual_service_tier: log.actual_service_tier,
        endpoint: log.endpoint,
        user_agent: log.user_agent,
        metadata: MetadataSanitizer.safe_metadata(log.metadata || %{})
      })

    stringify_keys(projected)
  end

  @spec list_text(map()) :: String.t()
  def list_text(%{"items" => items, "total" => total, "offset" => offset}) do
    first_line = first_line(items, total, offset)

    if items == [] do
      first_line
    else
      "request logs"
      |> ReadableText.list(text_rows(items), list_text_fields(), total: total, offset: offset)
      |> replace_first_line(first_line)
    end
  end

  @spec detail_text(map()) :: String.t()
  def detail_text(%{"status" => "ok", "item" => item}) do
    ReadableText.detail("request log", detail_text_row(item), detail_text_fields())
  end

  def detail_text(%{"status" => "not_found"}), do: ReadableText.not_found("request log")

  defp first_line(items, total, offset) do
    shown_count = min(length(items), 10)
    status_text = tally_text(items, "status")

    "#{shown_count} request logs returned; total #{total}; offset #{offset}; statuses #{status_text}"
  end

  defp text_rows(items), do: Enum.map(items, &text_row/1)

  defp text_row(item) do
    item
    |> Map.take([
      "admitted_at",
      "completed_at",
      "endpoint",
      "status",
      "requested_model",
      "transport",
      "usage_status",
      "latency_ms"
    ])
    |> Map.put("pool", pool_text(item))
    |> Map.put("retries", Map.get(item, "retry_count") || 0)
  end

  defp detail_text_row(item) do
    item
    |> text_row()
    |> maybe_put_value("response", Map.get(item, "response_status_code"))
    |> Map.put("upstream", upstream_text(item))
    |> maybe_put_metadata_summary(Map.get(item, "metadata"))
  end

  defp list_text_fields do
    [
      {"admitted_at", "admitted_at"},
      {"completed_at", "completed_at"},
      {"pool", "pool", required: true},
      {"endpoint", "route"},
      {"status", "status"},
      {"requested_model", "model"},
      {"transport", "transport"},
      {"usage_status", "usage"},
      {"latency_ms", "latency_ms"},
      {"retries", "retries", required: true}
    ]
  end

  defp detail_text_fields do
    list_text_fields() ++
      [
        {"response", "response"},
        {"upstream", "upstream", required: true},
        {"metadata_summary", "metadata"}
      ]
  end

  defp pool_text(item) do
    blank_to_nil(Map.get(item, "pool_slug")) || blank_to_nil(Map.get(item, "pool_name")) ||
      "unknown"
  end

  defp upstream_text(item) do
    blank_to_nil(Map.get(item, "upstream_identity_label")) ||
      blank_to_nil(Map.get(item, "upstream_account_label")) || "unknown"
  end

  defp maybe_put_value(row, _key, nil), do: row
  defp maybe_put_value(row, key, value), do: Map.put(row, key, value)

  defp maybe_put_metadata_summary(row, metadata)
       when is_map(metadata) and map_size(metadata) > 0 do
    Map.put(row, "metadata_summary", metadata_summary(metadata))
  end

  defp maybe_put_metadata_summary(row, _metadata), do: row

  defp metadata_summary(metadata) do
    keys =
      metadata
      |> Enum.filter(fn {_key, value} -> useful_metadata_value?(value) end)
      |> Enum.map(fn {key, _value} -> ReadableText.scalar(key) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()
      |> Enum.take(5)

    "#{length(keys)} safe metadata keys" <>
      if(keys == [], do: "", else: ": #{Enum.join(keys, ", ")}")
  end

  defp useful_metadata_value?("[REDACTED]"), do: false
  defp useful_metadata_value?(nil), do: false

  defp useful_metadata_value?(value) when is_map(value),
    do: Enum.any?(value, fn {_key, child} -> useful_metadata_value?(child) end)

  defp useful_metadata_value?(value) when is_list(value),
    do: Enum.any?(value, &useful_metadata_value?/1)

  defp useful_metadata_value?(_value), do: true

  defp replace_first_line(text, first_line) do
    text
    |> String.split("\n", parts: 2)
    |> case do
      [_old_first_line, rest] -> first_line <> "\n" <> rest
      [_old_first_line] -> first_line
    end
  end

  defp tally_text([], _field), do: "none"

  defp tally_text(items, field) do
    items
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {value, _count} -> value end)
    |> Enum.map_join(", ", fn {value, count} -> "#{value}:#{count}" end)
    |> case do
      "" -> "none"
      text -> text
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), MetadataSanitizer.safe_value(value)} end)
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
