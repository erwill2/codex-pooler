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
    # Avoid unconditional String.replace allocation when \r is absent
    data = if String.contains?(data, "\r"), do: String.replace(data, "\r\n", "\n"), else: data
    bounded? = Keyword.fetch!(opts, :bounded?)

    case String.split(data, "\n\n") do
      [single] ->
        {[], maybe_bound_incomplete_sse_block(single, bounded?)}

      parts ->
        {blocks, buffer} = extract_sse_blocks(parts, [])
        {blocks, maybe_bound_incomplete_sse_block(buffer, bounded?)}
    end
  end

  # Single-pass tail-recursive accumulator avoids multi-pass List/Enum traversals
  defp extract_sse_blocks([last], acc) do
    {Enum.reverse(acc), last}
  end

  defp extract_sse_blocks(["" | rest], acc) do
    extract_sse_blocks(rest, acc)
  end

  defp extract_sse_blocks([block | rest], acc) do
    extract_sse_blocks(rest, [block | acc])
  end

  @spec sse_field(binary(), binary()) :: binary() | nil
  def sse_field(block, name) do
    prefix = name <> ":"

    block
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn line ->
      if String.starts_with?(line, prefix) do
        [line |> String.replace_prefix(prefix, "") |> String.trim_leading()]
      else
        []
      end
    end)
    |> case do
      [] -> nil
      values -> Enum.join(values, "\n")
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
