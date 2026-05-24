defmodule CodexPooler.Access.InviteAcceptance do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type attrs :: map()

  schema "invite_acceptances" do
    field :invite_id, :binary_id
    field :pool_id, :binary_id
    field :upstream_identity_id, :binary_id
    field :pool_upstream_assignment_id, :binary_id
    field :onboarding_method, :string
    field :accepted_by_email, :string
    field :accepted_at, :utc_datetime_usec
    field :details, :map
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(acceptance, attrs) do
    acceptance
    |> cast(attrs, [
      :invite_id,
      :pool_id,
      :upstream_identity_id,
      :pool_upstream_assignment_id,
      :onboarding_method,
      :accepted_by_email,
      :accepted_at,
      :details
    ])
    |> validate_required([
      :invite_id,
      :pool_id,
      :upstream_identity_id,
      :onboarding_method,
      :accepted_at,
      :details
    ])
    |> validate_inclusion(:onboarding_method, ~w(invite wizard browser device import))
    |> unique_constraint(:invite_id, name: :invite_acceptances_invite_id_uq)
  end
end
