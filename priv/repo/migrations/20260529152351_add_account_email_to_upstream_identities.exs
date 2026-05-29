defmodule CodexPooler.Repo.Migrations.AddAccountEmailToUpstreamIdentities do
  use Ecto.Migration

  def up do
    alter table(:upstream_identities) do
      add :account_email, :text
    end

    execute """
    UPDATE upstream_identities
    SET account_email = lower(NULLIF(BTRIM(metadata->>'account_email'), ''))
    WHERE account_email IS NULL
      AND NULLIF(BTRIM(metadata->>'account_email'), '') ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
    """

    execute """
    UPDATE upstream_identities AS identity
    SET account_email = source.account_email
    FROM (
      SELECT DISTINCT ON (acceptance.upstream_identity_id)
        acceptance.upstream_identity_id,
        lower(NULLIF(BTRIM(acceptance.accepted_by_email), '')) AS account_email
      FROM invite_acceptances AS acceptance
      WHERE NULLIF(BTRIM(acceptance.accepted_by_email), '') ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
      ORDER BY acceptance.upstream_identity_id, acceptance.accepted_at DESC, acceptance.id DESC
    ) AS source
    WHERE identity.id = source.upstream_identity_id
      AND identity.account_email IS NULL
    """

    execute """
    UPDATE upstream_identities AS identity
    SET account_email = source.account_email
    FROM (
      SELECT DISTINCT ON (acceptance.upstream_identity_id)
        acceptance.upstream_identity_id,
        lower(NULLIF(BTRIM(invite.invited_email), '')) AS account_email
      FROM invite_acceptances AS acceptance
      JOIN invites AS invite ON invite.id = acceptance.invite_id
      WHERE NULLIF(BTRIM(invite.invited_email), '') ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
      ORDER BY acceptance.upstream_identity_id, acceptance.accepted_at DESC, acceptance.id DESC
    ) AS source
    WHERE identity.id = source.upstream_identity_id
      AND identity.account_email IS NULL
    """

    execute """
    UPDATE upstream_identities
    SET account_email = lower(NULLIF(BTRIM(chatgpt_account_id), ''))
    WHERE account_email IS NULL
      AND NULLIF(BTRIM(chatgpt_account_id), '') ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
    """
  end

  def down do
    alter table(:upstream_identities) do
      remove :account_email
    end
  end
end
