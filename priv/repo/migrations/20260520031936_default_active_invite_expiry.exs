defmodule CodexPooler.Repo.Migrations.DefaultActiveInviteExpiry do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE public.invites
    SET expires_at = created_at + interval '24 hours',
        updated_at = now()
    WHERE status = 'active'
      AND expires_at IS NULL
    """)
  end

  def down do
    :ok
  end
end
