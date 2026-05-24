defmodule CodexPooler.Repo.Migrations.AllowExternalUsageRequestLogs do
  use Ecto.Migration

  def change do
    alter table(:requests) do
      modify :api_key_id, :uuid, null: true
    end
  end
end
