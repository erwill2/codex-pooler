defmodule CodexPooler.MCP.OperatorMCPKey do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @derive {Inspect, except: [:key_hash]}

  @type t :: %__MODULE__{}

  schema "operator_mcp_keys" do
    field :operator_id, :binary_id
    field :label, :string
    field :key_prefix, :string
    field :key_hash, :binary

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(key, attrs) do
    key
    |> cast(attrs, [:operator_id, :label, :key_prefix, :key_hash])
    |> update_change(:label, &String.trim/1)
    |> validate_required([:operator_id, :label, :key_prefix, :key_hash])
    |> validate_length(:label, max: 160)
    |> unique_constraint(:key_prefix, name: :operator_mcp_keys_prefix_uq)
    |> unique_constraint(:key_hash, name: :operator_mcp_keys_hash_uq)
  end

  @spec label_changeset(t(), map()) :: Ecto.Changeset.t()
  def label_changeset(key, attrs) do
    key
    |> cast(attrs, [:label])
    |> update_change(:label, &String.trim/1)
    |> validate_required([:label])
    |> validate_length(:label, max: 160)
  end
end
