defmodule CodexPooler.Accounts.TOTPSetting do
  @moduledoc false
  use CodexPooler.Schema

  schema "totp_settings" do
    field :user_id, :binary_id
    field :secret_ciphertext, :binary
    field :secret_key_version, :string
    field :recovery_generation, :integer
    field :status, :string
    field :enrolled_at, :utc_datetime_usec
    field :verified_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
