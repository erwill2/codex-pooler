defmodule CodexPooler.SearchPattern do
  @moduledoc false

  @spec contains(String.t()) :: String.t()
  def contains(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%" <> escaped <> "%"
  end
end
