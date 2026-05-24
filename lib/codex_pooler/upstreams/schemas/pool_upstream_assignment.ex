defmodule CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment do
  @moduledoc """
  Persisted assignment between a pool and an upstream account identity.

  The `CodexPooler.Upstreams.Schemas.*` namespace is intentional for upstream
  database structs so runtime callers can distinguish schemas from the operator
  context facade.
  """
  use CodexPooler.Schema

  import Ecto.Changeset

  @statuses ~w(pending active paused refresh_due refreshing refresh_failed reauth_required deleted disabled errored)
  @health_statuses ~w(unknown active cooldown degraded disabled errored)
  @eligibility_statuses ~w(eligible ineligible)

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type status :: String.t()
  @type health_status :: String.t()
  @type eligibility_status :: String.t()

  schema "pool_upstream_assignments" do
    field :pool_id, :binary_id
    field :upstream_identity_id, :binary_id
    field :assignment_label, :string
    field :status, :string
    field :health_status, :string
    field :eligibility_status, :string
    field :cooldown_until, :utc_datetime_usec
    field :last_healthcheck_at, :utc_datetime_usec
    field :last_successful_refresh_at, :utc_datetime_usec
    field :last_successful_sync_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :created_by_user_id, :binary_id
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :metadata, :map
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :pool_id,
      :upstream_identity_id,
      :assignment_label,
      :status,
      :health_status,
      :eligibility_status,
      :cooldown_until,
      :last_healthcheck_at,
      :last_successful_refresh_at,
      :last_successful_sync_at,
      :disabled_at,
      :created_by_user_id,
      :created_at,
      :updated_at,
      :metadata
    ])
    |> update_change(:assignment_label, &String.trim/1)
    |> validate_required([
      :pool_id,
      :upstream_identity_id,
      :assignment_label,
      :status,
      :health_status,
      :eligibility_status,
      :created_at,
      :updated_at,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:health_status, @health_statuses)
    |> validate_inclusion(:eligibility_status, @eligibility_statuses)
    |> unique_constraint(:upstream_identity_id, name: :pool_upstream_assignments_identity_uq)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec health_statuses() :: [health_status()]
  def health_statuses, do: @health_statuses

  @spec eligibility_statuses() :: [eligibility_status()]
  def eligibility_statuses, do: @eligibility_statuses

  @spec pending_status() :: status()
  def pending_status, do: "pending"

  @spec active_status() :: status()
  def active_status, do: "active"

  @spec paused_status() :: status()
  def paused_status, do: "paused"

  @spec refresh_due_status() :: status()
  def refresh_due_status, do: "refresh_due"

  @spec refreshing_status() :: status()
  def refreshing_status, do: "refreshing"

  @spec refresh_failed_status() :: status()
  def refresh_failed_status, do: "refresh_failed"

  @spec reauth_required_status() :: status()
  def reauth_required_status, do: "reauth_required"

  @spec deleted_status() :: status()
  def deleted_status, do: "deleted"

  @spec disabled_status() :: status()
  def disabled_status, do: "disabled"

  @spec errored_status() :: status()
  def errored_status, do: "errored"

  @spec unknown_health_status() :: health_status()
  def unknown_health_status, do: "unknown"

  @spec active_health_status() :: health_status()
  def active_health_status, do: "active"

  @spec cooldown_health_status() :: health_status()
  def cooldown_health_status, do: "cooldown"

  @spec degraded_health_status() :: health_status()
  def degraded_health_status, do: "degraded"

  @spec disabled_health_status() :: health_status()
  def disabled_health_status, do: "disabled"

  @spec errored_health_status() :: health_status()
  def errored_health_status, do: "errored"

  @spec eligible_status() :: eligibility_status()
  def eligible_status, do: "eligible"

  @spec ineligible_status() :: eligibility_status()
  def ineligible_status, do: "ineligible"
end
