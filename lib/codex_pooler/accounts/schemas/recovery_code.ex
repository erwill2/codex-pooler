defmodule CodexPooler.Accounts.RecoveryCode do
  @moduledoc false
  use CodexPooler.Schema

  schema "recovery_codes" do
    field :user_id, :binary_id
    field :totp_setting_id, :binary_id
    field :code_hash, :binary
    field :status, :string
    field :created_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
  end
end
