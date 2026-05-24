defmodule CodexPooler.Repo.Migrations.CreateOperatorMcpSettings do
  use Ecto.Migration

  def change do
    create table(:operator_mcp_settings, primary_key: false) do
      add :operator_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :enabled, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
