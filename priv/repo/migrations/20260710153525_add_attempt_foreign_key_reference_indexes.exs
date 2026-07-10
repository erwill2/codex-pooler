defmodule CodexPooler.Repo.Migrations.AddAttemptForeignKeyReferenceIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:ledger_entries, [:attempt_id], concurrently: true)
    create index(:request_log_facts, [:latest_attempt_id], concurrently: true)
  end
end
