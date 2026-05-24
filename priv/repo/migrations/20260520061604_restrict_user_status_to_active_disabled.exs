defmodule CodexPooler.Repo.Migrations.RestrictUserStatusToActiveDisabled do
  use Ecto.Migration

  def up do
    execute("UPDATE users SET status = 'disabled', updated_at = now() WHERE status = 'locked'")

    execute("ALTER TABLE users DROP CONSTRAINT IF EXISTS users_status_check")

    execute("""
    ALTER TABLE users
    ADD CONSTRAINT users_status_check
    CHECK (status = ANY (ARRAY['active'::text, 'disabled'::text]))
    """)
  end

  def down do
    execute("ALTER TABLE users DROP CONSTRAINT IF EXISTS users_status_check")

    execute("""
    ALTER TABLE users
    ADD CONSTRAINT users_status_check
    CHECK (status = ANY (ARRAY['active'::text, 'disabled'::text, 'locked'::text]))
    """)
  end
end
