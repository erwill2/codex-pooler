defmodule CodexPooler.Accounts.Session do
  @moduledoc false
  use CodexPooler.Schema

  schema "sessions" do
    belongs_to :user, CodexPooler.Accounts.User
    field :session_token_hash, :binary
    field :status, :string
    field :expires_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :ip_address, CodexPooler.Postgres.INET
    field :user_agent, :string
    field :created_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
  end
end
