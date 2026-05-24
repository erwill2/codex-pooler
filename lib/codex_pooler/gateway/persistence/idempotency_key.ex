defmodule CodexPooler.Gateway.Persistence.IdempotencyKey do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @statuses ~w(in_progress succeeded failed expired)

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type status :: String.t()

  schema "gateway_idempotency_keys" do
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :request_id, :binary_id
    field :codex_file_id, :binary_id
    field :scope, :string
    field :key_hash, :binary
    field :status, :string
    field :expires_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :response_metadata, :map
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(key, attrs) do
    key
    |> cast(attrs, [
      :pool_id,
      :api_key_id,
      :request_id,
      :codex_file_id,
      :scope,
      :key_hash,
      :status,
      :expires_at,
      :completed_at,
      :response_metadata,
      :created_at,
      :updated_at
    ])
    |> validate_required([
      :pool_id,
      :api_key_id,
      :scope,
      :key_hash,
      :status,
      :expires_at,
      :response_metadata,
      :created_at,
      :updated_at
    ])
    |> validate_inclusion(:status, @statuses)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec in_progress_status() :: status()
  def in_progress_status, do: "in_progress"

  @spec succeeded_status() :: status()
  def succeeded_status, do: "succeeded"

  @spec failed_status() :: status()
  def failed_status, do: "failed"

  @spec expired_status() :: status()
  def expired_status, do: "expired"

  @spec expirable_statuses() :: [status()]
  def expirable_statuses, do: [in_progress_status(), succeeded_status()]
end
