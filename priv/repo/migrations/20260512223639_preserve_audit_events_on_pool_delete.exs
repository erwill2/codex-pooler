defmodule CodexPooler.Repo.Migrations.PreserveAuditEventsOnPoolDelete do
  use Ecto.Migration

  def up do
    drop constraint(:audit_events, "audit_events_pool_id_fkey")

    alter table(:audit_events) do
      modify :pool_id, references(:pools, type: :binary_id, on_delete: :nilify_all)
    end
  end

  def down do
    drop constraint(:audit_events, "audit_events_pool_id_fkey")

    alter table(:audit_events) do
      modify :pool_id, references(:pools, type: :binary_id, on_delete: :delete_all)
    end
  end
end
