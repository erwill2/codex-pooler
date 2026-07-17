defmodule CodexPooler.Gateway.RequestCompression.TokenCounter.BPE do
  @moduledoc false

  @type ranks :: %{required(binary()) => non_neg_integer()}

  @spec count(binary(), ranks()) :: non_neg_integer()
  def count("", _ranks), do: 0

  def count(chunk, ranks) when is_binary(chunk) and is_map(ranks) do
    case Map.fetch(ranks, chunk) do
      {:ok, _rank} ->
        1

      :error ->
        chunk
        |> byte_pieces()
        |> merge_count(ranks)
    end
  end

  @spec encode(binary(), ranks()) :: [non_neg_integer()]
  def encode("", _ranks), do: []

  def encode(chunk, ranks) when is_binary(chunk) and is_map(ranks) do
    case Map.fetch(ranks, chunk) do
      {:ok, rank} ->
        [rank]

      :error ->
        chunk
        |> byte_pieces()
        |> merge_pieces(ranks)
        |> Enum.map(&Map.fetch!(ranks, &1))
    end
  end

  defp merge_count(pieces, ranks), do: pieces |> merge_pieces(ranks) |> length()

  defp byte_pieces(chunk) do
    for <<byte <- chunk>>, do: <<byte>>
  end

  defp merge_pieces([], _ranks), do: []
  defp merge_pieces([_piece] = pieces, _ranks), do: pieces

  defp merge_pieces(pieces, ranks) do
    case lowest_ranked_pair(pieces, ranks) do
      nil -> pieces
      index -> pieces |> merge_at(index) |> merge_pieces(ranks)
    end
  end

  defp lowest_ranked_pair([first, second | rest], ranks) do
    best_rank = pair_rank(first, second, ranks)
    best_index = if is_nil(best_rank), do: nil, else: 0

    lowest_ranked_pair(rest, second, ranks, 0, best_rank, best_index)
  end

  defp lowest_ranked_pair(_pieces, _ranks), do: nil

  defp lowest_ranked_pair([], _previous, _ranks, _index, nil, best_index), do: best_index
  defp lowest_ranked_pair([], _previous, _ranks, _index, _best_rank, best_index), do: best_index

  defp lowest_ranked_pair([next | rest], previous, ranks, index, best_rank, best_index) do
    pair_index = index + 1
    rank = pair_rank(previous, next, ranks)

    {best_rank, best_index} =
      if rank && (is_nil(best_rank) || rank < best_rank) do
        {rank, pair_index}
      else
        {best_rank, best_index}
      end

    lowest_ranked_pair(rest, next, ranks, pair_index, best_rank, best_index)
  end

  defp pair_rank(first, second, ranks), do: Map.get(ranks, first <> second)

  # Performance optimized merge_at/2 to avoid Enum.split/2 and list concatenation (++/2).
  # Tail-recursively traverses the list exactly once up to the index, then uses the
  # native fast Enum.reverse/2 to reverse the accumulator onto the remainder.
  defp merge_at(pieces, index) do
    merge_at(pieces, index, [])
  end

  defp merge_at([first, second | rest], 0, acc) do
    Enum.reverse(acc, [first <> second | rest])
  end

  defp merge_at([first | rest], index, acc) do
    merge_at(rest, index - 1, [first | acc])
  end
end
