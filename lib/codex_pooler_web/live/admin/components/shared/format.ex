defmodule CodexPoolerWeb.Admin.Format do
  @moduledoc """
  Shared formatting helpers for operator-facing admin presentation.
  """

  @money_places 2
  @micros_per_usd Decimal.new(1_000_000)
  @token_scales [
    {1_000_000_000, "B"},
    {1_000_000, "M"},
    {1_000, "k"}
  ]

  @spec money(Decimal.t() | integer() | float()) :: String.t()
  def money(%Decimal{} = usd) do
    usd
    |> Decimal.round(@money_places)
    |> Decimal.to_string(:normal)
    |> fixed_decimal_places(@money_places)
    |> add_group_separators()
    |> then(&"$#{&1}")
  end

  def money(value) when is_integer(value), do: value |> Decimal.new() |> money()
  def money(value) when is_float(value), do: value |> Decimal.from_float() |> money()

  @spec money_from_micros(integer()) :: String.t()
  def money_from_micros(micros) when is_integer(micros) do
    micros
    |> Decimal.new()
    |> Decimal.div(@micros_per_usd)
    |> money()
  end

  @spec token_count(integer() | float() | Decimal.t() | nil) :: String.t()
  def token_count(nil), do: "0"

  def token_count(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer() |> token_count()

  def token_count(value) when is_float(value), do: value |> round() |> token_count()

  def token_count(value) when is_integer(value) do
    sign = if value < 0, do: "-", else: ""
    absolute = abs(value)

    case Enum.find(@token_scales, fn {scale, _suffix} -> absolute >= scale end) do
      nil ->
        sign <> Integer.to_string(absolute)

      {scale, suffix} ->
        sign <> compact_scaled(absolute, scale) <> suffix
    end
  end

  @spec integer(integer() | Decimal.t() | nil) :: String.t()
  def integer(nil), do: "0"

  def integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer() |> integer()

  def integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> add_group_separators()
  end

  defp compact_scaled(value, scale) do
    value
    |> Kernel./(scale)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp fixed_decimal_places(value, places) do
    case String.split(value, ".", parts: 2) do
      [whole] ->
        whole <> "." <> String.duplicate("0", places)

      [whole, fraction] ->
        whole <> "." <> (fraction |> String.pad_trailing(places, "0") |> String.slice(0, places))
    end
  end

  defp add_group_separators(value) do
    {sign, value} =
      case value do
        "-" <> unsigned -> {"-", unsigned}
        unsigned -> {"", unsigned}
      end

    [whole | rest] = String.split(value, ".", parts: 2)

    grouped =
      whole
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.map(&Enum.reverse/1)
      |> Enum.reverse()
      |> Enum.map_join(",", &Enum.join/1)

    sign <> Enum.join([grouped | rest], ".")
  end
end
