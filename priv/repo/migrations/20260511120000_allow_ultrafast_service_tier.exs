defmodule CodexPooler.Repo.Migrations.AllowUltrafastServiceTier do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE api_keys
    DROP CONSTRAINT api_keys_enforced_service_tier_check
    """

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_enforced_service_tier_check
    CHECK (enforced_service_tier IS NULL OR enforced_service_tier = ANY (ARRAY['auto'::text, 'default'::text, 'flex'::text, 'priority'::text, 'ultrafast'::text]))
    """
  end

  def down do
    execute """
    ALTER TABLE api_keys
    DROP CONSTRAINT api_keys_enforced_service_tier_check
    """

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_enforced_service_tier_check
    CHECK (enforced_service_tier IS NULL OR enforced_service_tier = ANY (ARRAY['auto'::text, 'default'::text, 'flex'::text, 'priority'::text]))
    """
  end
end
