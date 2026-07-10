defmodule CodexPooler.Repo.Migrations.AddLedgerForeignKeyReferenceIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:ledger_entries, [:correction_of_entry_id], concurrently: true)
    create index(:request_log_facts, [:latest_settlement_entry_id], concurrently: true)
  end
end
