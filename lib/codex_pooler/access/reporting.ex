defmodule CodexPooler.Access.Reporting do
  @moduledoc """
  Read-only access projections for admin/reporting surfaces.
  """

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Repo

  @spec api_keys_by_id([Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => map()}
  def api_keys_by_id([]), do: %{}

  def api_keys_by_id(ids) do
    APIKey
    |> where([key], key.id in ^ids)
    |> select([key], %{id: key.id, display_name: key.display_name})
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end
end
