defmodule CodexPooler.MCP.OperatorMCPSettings do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:operator_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "operator_mcp_settings" do
    field :enabled, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:operator_id, :enabled])
    |> validate_required([:operator_id, :enabled])
  end
end
