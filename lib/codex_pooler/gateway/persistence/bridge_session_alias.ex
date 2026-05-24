defmodule CodexPooler.Gateway.Persistence.BridgeSessionAlias do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @alias_kinds ~w(turn_state previous_response_id session_header canonical_session_key)
  @statuses ~w(active expired replaced)

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type alias_kind :: String.t()
  @type status :: String.t()

  schema "bridge_session_aliases" do
    field :codex_session_id, :binary_id
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :alias_kind, :string
    field :alias_hash, :binary
    field :alias_preview, :string
    field :status, :string
    field :expires_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :metadata, :map
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(alias_record, attrs) do
    alias_record
    |> cast(attrs, [
      :codex_session_id,
      :pool_id,
      :api_key_id,
      :alias_kind,
      :alias_hash,
      :alias_preview,
      :status,
      :expires_at,
      :last_seen_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_required([
      :codex_session_id,
      :pool_id,
      :api_key_id,
      :alias_kind,
      :alias_hash,
      :status,
      :expires_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_inclusion(:alias_kind, @alias_kinds)
    |> validate_inclusion(:status, @statuses)
  end

  @spec alias_kinds() :: [alias_kind()]
  def alias_kinds, do: @alias_kinds

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec active_status() :: status()
  def active_status, do: "active"

  @spec expired_status() :: status()
  def expired_status, do: "expired"

  @spec replaced_status() :: status()
  def replaced_status, do: "replaced"
end
