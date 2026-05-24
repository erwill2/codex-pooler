defmodule CodexPooler.Gateway.Persistence.RoutingCircuitState do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @statuses ~w(closed open half_open)

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type status :: String.t()

  schema "routing_circuit_states" do
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :pool_upstream_assignment_id, :binary_id
    field :upstream_identity_id, :binary_id
    field :model_identifier, :string
    field :route_class, :string
    field :status, :string
    field :reason_code, :string
    field :failure_count, :integer
    field :success_count, :integer
    field :opened_at, :utc_datetime_usec
    field :half_opened_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :next_probe_at, :utc_datetime_usec
    field :last_failure_at, :utc_datetime_usec
    field :last_success_at, :utc_datetime_usec
    field :metadata, :map
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(state, attrs) do
    state
    |> cast(attrs, [
      :pool_id,
      :api_key_id,
      :pool_upstream_assignment_id,
      :upstream_identity_id,
      :model_identifier,
      :route_class,
      :status,
      :reason_code,
      :failure_count,
      :success_count,
      :opened_at,
      :half_opened_at,
      :closed_at,
      :next_probe_at,
      :last_failure_at,
      :last_success_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_required([
      :pool_id,
      :pool_upstream_assignment_id,
      :model_identifier,
      :route_class,
      :status,
      :failure_count,
      :success_count,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:failure_count, greater_than_or_equal_to: 0)
    |> validate_number(:success_count, greater_than_or_equal_to: 0)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec closed_status() :: status()
  def closed_status, do: "closed"

  @spec open_status() :: status()
  def open_status, do: "open"

  @spec half_open_status() :: status()
  def half_open_status, do: "half_open"
end
