defmodule CodexPooler.Pools.Membership do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  alias CodexPooler.Pools.Authorization

  @type t :: %__MODULE__{}
  @type attrs :: map()

  schema "memberships" do
    field :user_id, :binary_id
    field :role, :string
    field :status, :string
    field :created_by_user_id, :binary_id
    field :created_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :role, :status, :created_by_user_id, :created_at, :revoked_at])
    |> validate_required([:user_id, :role, :status])
    |> validate_inclusion(:role, Authorization.role_values())
    |> validate_inclusion(:status, ["active", "revoked"])
    |> unique_constraint(:role, name: :memberships_single_instance_owner_active_uq)
    |> unique_constraint(:role, name: :memberships_global_role_active_uq)
  end
end
