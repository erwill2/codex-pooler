defmodule CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions

  @oversized_event [:codex_pooler, :gateway, :stream_buffer, :oversized]
  @truncated_event [:codex_pooler, :gateway, :stream_buffer, :truncated]
  @unknown "unknown"

  @type event_opts :: [
          request_options: RequestOptions.t(),
          endpoint: String.t() | nil,
          transport: String.t() | atom() | nil,
          route_class: String.t() | atom() | nil
        ]

  @spec record_oversized_incomplete(String.t(), non_neg_integer(), pos_integer(), event_opts()) ::
          :ok
  def record_oversized_incomplete(buffer, bytes, max_bytes, opts \\ [])
      when is_binary(buffer) and is_integer(bytes) and is_integer(max_bytes) do
    execute(@oversized_event, buffer, bytes, max_bytes, opts)
  end

  @spec record_retained_body_truncated(String.t(), non_neg_integer(), pos_integer(), event_opts()) ::
          :ok
  def record_retained_body_truncated(buffer, bytes, max_bytes, opts \\ [])
      when is_binary(buffer) and is_integer(bytes) and is_integer(max_bytes) do
    execute(@truncated_event, buffer, bytes, max_bytes, opts)
  end

  defp execute(event, buffer, bytes, max_bytes, opts) do
    :telemetry.execute(
      event,
      %{count: 1, bytes: bytes, max_bytes: max_bytes},
      metadata(buffer, opts)
    )
  end

  defp metadata(buffer, opts) do
    request_options = Keyword.get(opts, :request_options)

    %{
      buffer: safe_tag(buffer),
      transport: transport_tag(request_options, opts),
      route_class: route_class_tag(request_options, opts),
      endpoint: endpoint_tag(request_options, opts)
    }
  end

  defp transport_tag(%RequestOptions{transport: %{transport: transport}}, _opts),
    do: safe_tag(transport)

  defp transport_tag(_request_options, opts), do: opts |> Keyword.get(:transport) |> safe_tag()

  defp route_class_tag(%RequestOptions{transport: %{route_class: route_class}}, _opts),
    do: safe_tag(route_class)

  defp route_class_tag(_request_options, opts),
    do: opts |> Keyword.get(:route_class) |> safe_tag()

  defp endpoint_tag(%RequestOptions{transport: %{upstream_endpoint: endpoint}}, _opts),
    do: safe_tag(endpoint)

  defp endpoint_tag(_request_options, opts), do: opts |> Keyword.get(:endpoint) |> safe_tag()

  defp safe_tag(nil), do: @unknown
  defp safe_tag(value) when is_atom(value), do: Atom.to_string(value)

  defp safe_tag(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @unknown
      value -> value
    end
  end

  defp safe_tag(_value), do: @unknown
end
