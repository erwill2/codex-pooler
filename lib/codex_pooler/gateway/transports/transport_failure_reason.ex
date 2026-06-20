defmodule CodexPooler.Gateway.Transports.TransportFailureReason do
  @moduledoc false

  @max_reason_length 96
  @allowed_phases ~w(
    connect
    decode
    receive
    receive_timeout
    request
    send_control
    send_payload
    unexpected_frame
    upstream_close
  )

  @type transport_failure_metadata :: %{String.t() => String.t() | non_neg_integer() | boolean()}
  @type upstream_transport_error :: %{
          required(:status) => pos_integer(),
          required(:code) => String.t(),
          required(:message) => String.t(),
          required(:param) => nil,
          optional(:transport_failure) => transport_failure_metadata()
        }

  @spec safe_reason(term()) :: String.t() | nil
  def safe_reason(%Finch.TransportError{source: %Mint.TransportError{} = source}),
    do: safe_reason(source)

  def safe_reason(%Finch.HTTPError{source: %Mint.HTTPError{} = source}), do: safe_reason(source)
  def safe_reason(%{__struct__: _module, reason: reason}), do: safe_reason(reason)
  def safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  def safe_reason(reason) when is_binary(reason) do
    reason
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> truncate_reason()
    |> blank_to_nil()
  end

  def safe_reason(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.map(&safe_tuple_reason/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(3)
    |> Enum.join("_")
    |> blank_to_nil()
  end

  def safe_reason(_reason), do: nil

  @spec safe_exception(term()) :: String.t() | nil
  def safe_exception(%module{}) when is_atom(module), do: inspect(module)
  def safe_exception(_reason), do: nil

  @spec transport_failure_metadata(term(), map()) :: transport_failure_metadata()
  def transport_failure_metadata(reason, attrs) when is_map(attrs) do
    %{
      "exception" => safe_exception(reason),
      "reason_class" => safe_reason_class(reason),
      "reason" => safe_metadata_reason(reason),
      "phase" => safe_phase(Map.get(attrs, :phase) || Map.get(attrs, "phase")),
      "pre_visible_output" => safe_boolean(Map.get(attrs, :pre_visible_output)),
      "terminal_seen" => safe_boolean(Map.get(attrs, :terminal_seen)),
      "text_frame_count" => safe_non_negative_integer(Map.get(attrs, :text_frame_count))
    }
    |> compact_metadata()
  end

  @spec upstream_transport_error(term(), map()) :: upstream_transport_error()
  def upstream_transport_error(reason, attrs) when is_map(attrs) do
    %{
      status: 502,
      code: "upstream_network_error",
      message: "upstream request failed",
      param: nil
    }
    |> maybe_put_transport_failure(transport_failure_metadata(reason, attrs))
  end

  defp safe_tuple_reason(value) when is_atom(value), do: safe_reason(value)
  defp safe_tuple_reason(value) when is_tuple(value), do: safe_reason(value)
  defp safe_tuple_reason(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_tuple_reason(_value), do: nil

  defp safe_reason_class(%Finch.TransportError{source: %Mint.TransportError{} = source}),
    do: safe_reason_class(source)

  defp safe_reason_class(%Finch.HTTPError{source: %Mint.HTTPError{} = source}),
    do: safe_reason_class(source)

  defp safe_reason_class(%module{}) when is_atom(module), do: inspect(module)
  defp safe_reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason_class(reason) when is_binary(reason), do: "binary"

  defp safe_reason_class(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.find_value(&safe_tuple_reason/1)
  end

  defp safe_reason_class(_reason), do: nil

  defp safe_metadata_reason(%Finch.TransportError{source: %Mint.TransportError{} = source}),
    do: safe_metadata_reason(source)

  defp safe_metadata_reason(%Finch.HTTPError{source: %Mint.HTTPError{} = source}),
    do: safe_metadata_reason(source)

  defp safe_metadata_reason(%{__struct__: _module, reason: reason}),
    do: safe_metadata_reason(reason)

  defp safe_metadata_reason(reason) when is_atom(reason), do: safe_reason(reason)
  defp safe_metadata_reason(reason) when is_tuple(reason), do: safe_reason(reason)
  defp safe_metadata_reason(_reason), do: nil

  defp safe_phase(phase) when is_atom(phase), do: phase |> Atom.to_string() |> safe_phase()

  defp safe_phase(phase) when is_binary(phase) do
    phase
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> truncate_reason()
    |> blank_to_nil()
    |> allow_phase()
  end

  defp safe_phase(_phase), do: nil

  defp allow_phase(phase) when phase in @allowed_phases, do: phase
  defp allow_phase(_phase), do: nil

  defp safe_boolean(value) when is_boolean(value), do: value
  defp safe_boolean(_value), do: nil

  defp safe_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp safe_non_negative_integer(_value), do: nil

  defp truncate_reason(reason) when byte_size(reason) > @max_reason_length,
    do: binary_part(reason, 0, @max_reason_length)

  defp truncate_reason(reason), do: reason

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp compact_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_put_transport_failure(error, metadata) when map_size(metadata) > 0,
    do: Map.put(error, :transport_failure, metadata)

  defp maybe_put_transport_failure(error, _metadata), do: error
end
