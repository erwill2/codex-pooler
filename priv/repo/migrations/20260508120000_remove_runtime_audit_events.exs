defmodule CodexPooler.Repo.Migrations.RemoveRuntimeAuditEvents do
  use Ecto.Migration

  def up do
    execute("DELETE FROM audit_events WHERE action LIKE 'request.%' OR action LIKE 'file.%'")
  end

  def down do
    :ok
  end
end
