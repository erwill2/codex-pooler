defmodule CodexPooler.Gateway.RequestCompression.Strategies.JsonArrayLossless do
  @moduledoc """
  Conservative JSON-array request compression.

  This strategy only minifies valid JSON array text and returns a rewrite when
  local token counting proves a strict reduction. Dropping rows, object keys,
  values, or nested data is intentionally left out until a recoverability design
  exists.
  """

  alias CodexPooler.Gateway.RequestCompression.Strategies

  @strategy :json_array_lossless

  @spec compress(term(), Strategies.opts()) :: Strategies.result()
  def compress(content, opts \\ [])

  def compress(content, opts) when is_binary(content) do
    with {:ok, rows} when is_list(rows) <- Jason.decode(content, objects: :ordered_objects),
         {:ok, compressed} <- Jason.encode(rows) do
      Strategies.finalize(@strategy, content, compressed, %{row_count: length(rows)}, opts)
    else
      _skip -> :skip
    end
  end

  def compress(_content, _opts), do: :skip
end
