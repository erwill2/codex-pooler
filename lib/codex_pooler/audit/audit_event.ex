defmodule CodexPooler.Audit.AuditEvent do
  @moduledoc false
  use CodexPooler.Schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          occurred_at: DateTime.t() | nil,
          actor_type: String.t() | nil,
          actor_user_id: Ecto.UUID.t() | nil,
          pool_id: Ecto.UUID.t() | nil,
          request_id: Ecto.UUID.t() | nil,
          action: String.t() | nil,
          target_type: String.t() | nil,
          target_id: Ecto.UUID.t() | nil,
          outcome: String.t() | nil,
          correlation_id: String.t() | nil,
          ip_address: term(),
          details: map() | nil
        }

  schema "audit_events" do
    field :occurred_at, :utc_datetime_usec
    field :actor_type, :string
    field :actor_user_id, :binary_id
    field :pool_id, :binary_id
    field :request_id, :binary_id
    field :action, :string
    field :target_type, :string
    field :target_id, :binary_id
    field :outcome, :string
    field :correlation_id, :string
    field :ip_address, CodexPooler.Postgres.INET
    field :details, :map
  end
end
