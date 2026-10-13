defmodule CodexPooler.SearchPattern do
  @moduledoc false

  @doc """
  Escapes SQL LIKE wildcards (`%`, `_`) and backslashes (`\\`) in search strings
  and wraps the escaped result in `%` wildcards to prevent SQL LIKE wildcard injection.
  """
  @spec contains(term()) :: String.t()
  def contains(nil), do: "%%"

  def contains(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%" <> escaped <> "%"
  end

  def contains(value), do: value |> to_string() |> contains()
end
