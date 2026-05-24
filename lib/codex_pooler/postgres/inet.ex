defmodule CodexPooler.Postgres.INET do
  @moduledoc false

  use Ecto.Type

  def type, do: :inet

  def cast(nil), do: {:ok, nil}

  def cast(%Postgrex.INET{} = inet), do: {:ok, inet}

  def cast(value) when is_binary(value) do
    value
    |> String.to_charlist()
    |> cast_charlist()
  end

  def cast(_value), do: :error

  def dump(nil), do: {:ok, nil}
  def dump(%Postgrex.INET{} = inet), do: {:ok, inet}
  def dump(value) when is_binary(value), do: cast(value)
  def dump(_value), do: :error

  def load(nil), do: {:ok, nil}

  def load(%Postgrex.INET{address: address}) do
    {:ok, address |> :inet.ntoa() |> to_string()}
  end

  def load(_value), do: :error

  defp cast_charlist(value) do
    case :inet.parse_address(value) do
      {:ok, address} -> {:ok, %Postgrex.INET{address: address}}
      {:error, _reason} -> :error
    end
  end
end
