defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser do
  @moduledoc false

  @max_incomplete_sse_block_bytes 65_536

  @spec max_incomplete_sse_block_bytes() :: pos_integer()
  def max_incomplete_sse_block_bytes, do: @max_incomplete_sse_block_bytes

  @spec oversized_incomplete_sse_block?(binary()) :: boolean()
  def oversized_incomplete_sse_block?(buffer) when is_binary(buffer),
    do: byte_size(buffer) > @max_incomplete_sse_block_bytes

  @spec complete_sse_blocks(binary(), keyword()) :: {[binary()], binary()}
  def complete_sse_blocks(data, opts) do
    data = String.replace(data, "\r\n", "\n")
    bounded? = Keyword.fetch!(opts, :bounded?)

    if String.contains?(data, "\n\n") do
      {complete, buffer} =
        data
        |> String.split("\n\n")
        |> separate_buffer()

      {complete, maybe_bound_incomplete_sse_block(buffer, bounded?)}
    else
      {[], maybe_bound_incomplete_sse_block(data, bounded?)}
    end
  end

  # Single-pass tail-recursive decomposition: separates the trailing incomplete buffer
  # from completed non-empty SSE blocks, replacing ends_with?, Enum.drop, List.last,
  # and Enum.reject.
  defp separate_buffer(parts), do: do_separate_buffer(parts, [])

  defp do_separate_buffer([last], acc), do: {Enum.reverse(acc), last}
  defp do_separate_buffer(["" | tail], acc), do: do_separate_buffer(tail, acc)
  defp do_separate_buffer([head | tail], acc), do: do_separate_buffer(tail, [head | acc])

  @spec sse_field(binary(), binary()) :: binary() | nil
  def sse_field(block, name) do
    prefix = name <> ":"
    prefix_len = byte_size(prefix)

    block
    |> String.split("\n")
    |> extract_field_lines(prefix, prefix_len, [])
  end

  # Single-pass line extraction: avoids intermediate Enum.map and Enum.flat_map
  # allocations and uses O(1) binary_part slicing instead of String.replace_prefix.
  defp extract_field_lines([], _prefix, _prefix_len, []), do: nil

  defp extract_field_lines([], _prefix, _prefix_len, acc),
    do: acc |> Enum.reverse() |> Enum.join("\n")

  defp extract_field_lines([line | rest], prefix, prefix_len, acc) do
    line = String.trim(line)

    if String.starts_with?(line, prefix) do
      value =
        line |> binary_part(prefix_len, byte_size(line) - prefix_len) |> String.trim_leading()

      extract_field_lines(rest, prefix, prefix_len, [value | acc])
    else
      extract_field_lines(rest, prefix, prefix_len, acc)
    end
  end

  @spec decode_sse_data(term()) :: map()
  def decode_sse_data(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{}
    end
  end

  def decode_sse_data(_data), do: %{}

  @spec valid_json?(term()) :: boolean()
  def valid_json?(body) when is_binary(body), do: match?({:ok, _}, Jason.decode(body))
  def valid_json?(_body), do: false

  @spec stream_block_event(binary()) :: {String.t() | nil, map()}
  def stream_block_event(block) do
    data = sse_field(block, "data")
    decoded = if is_binary(data), do: decode_sse_data(data), else: decode_sse_data(block)
    event_type = sse_field(block, "event") || decoded_string(decoded, "type")

    {event_type, decoded}
  end

  defp decoded_string(decoded, key) when is_map(decoded) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp maybe_bound_incomplete_sse_block(buffer, false), do: buffer

  defp maybe_bound_incomplete_sse_block(buffer, true) do
    if oversized_incomplete_sse_block?(buffer), do: "", else: buffer
  end
end
