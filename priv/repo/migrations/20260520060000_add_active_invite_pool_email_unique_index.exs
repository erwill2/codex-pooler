defmodule CodexPooler.Repo.Migrations.AddActiveInvitePoolEmailUniqueIndex do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE public.invites
    SET status = 'expired',
        updated_at = now()
    WHERE status = 'active'
      AND expires_at IS NOT NULL
      AND expires_at <= now()
    """)

    execute("""
    WITH ranked AS (
      SELECT id,
             row_number() OVER (
               PARTITION BY pool_id, invited_email
               ORDER BY created_at DESC, id DESC
             ) AS row_number
      FROM public.invites
      WHERE status = 'active'
    )
    UPDATE public.invites invite
    SET status = 'expired',
        updated_at = now()
    FROM ranked
    WHERE invite.id = ranked.id
      AND ranked.row_number > 1
    """)

    create unique_index(:invites, [:pool_id, :invited_email],
             name: :invites_active_pool_email_uq,
             where: "status = 'active'"
           )
  end

  def down do
    drop index(:invites, [:pool_id, :invited_email], name: :invites_active_pool_email_uq)
  end
end
