defmodule CodexPooler.Accounts.PlatformBootstrapState do
  use Ecto.Schema

  @primary_key {:singleton, :boolean, autogenerate: false}
  @foreign_key_type :binary_id

  schema "platform_bootstrap_state" do
    field :status, :string
    field :owner_user_id, :binary_id
    field :completed_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
