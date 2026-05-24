defmodule CodexPooler.Gateway.Persistence.CodexSession do
  @moduledoc false
  use CodexPooler.Schema

  @type t :: %__MODULE__{}

  schema "codex_sessions" do
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :session_key, :string
    field :conversation_key, :string
    field :pool_upstream_assignment_id, :binary_id
    field :status, :string
    field :owner_instance_id, :string
    field :owner_lease_token, :binary_id
    field :owner_lease_expires_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :disconnected_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
