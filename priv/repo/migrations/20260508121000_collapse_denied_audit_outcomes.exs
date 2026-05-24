defmodule CodexPooler.Repo.Migrations.CollapseDeniedAuditOutcomes do
  use Ecto.Migration

  def up do
    execute("UPDATE audit_events SET outcome = 'failure' WHERE outcome = 'denied'")

    execute("ALTER TABLE audit_events DROP CONSTRAINT audit_events_outcome_check")

    execute("""
    ALTER TABLE audit_events
    ADD CONSTRAINT audit_events_outcome_check
    CHECK (outcome = ANY (ARRAY['success'::text, 'failure'::text]))
    """)
  end

  def down do
    execute("ALTER TABLE audit_events DROP CONSTRAINT audit_events_outcome_check")

    execute("""
    ALTER TABLE audit_events
    ADD CONSTRAINT audit_events_outcome_check
    CHECK (outcome = ANY (ARRAY['success'::text, 'failure'::text, 'denied'::text]))
    """)
  end
end
