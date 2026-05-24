defmodule CodexPooler.Repo.Migrations.NullifyModelLogReferencesOnDelete do
  use Ecto.Migration

  @model_reference_constraints [
    {"requests", "requests_model_id_fkey"},
    {"attempts", "attempts_model_id_fkey"},
    {"ledger_entries", "ledger_entries_model_id_fkey"}
  ]

  def up do
    for {table, constraint} <- @model_reference_constraints do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{constraint}")

      execute("""
      ALTER TABLE #{table}
        ADD CONSTRAINT #{constraint}
        FOREIGN KEY (model_id)
        REFERENCES models(id)
        ON DELETE SET NULL
      """)
    end
  end

  def down do
    for {table, constraint} <- @model_reference_constraints do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{constraint}")

      execute("""
      ALTER TABLE #{table}
        ADD CONSTRAINT #{constraint}
        FOREIGN KEY (model_id)
        REFERENCES models(id)
      """)
    end
  end
end
