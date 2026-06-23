defmodule CodexPooler.Repo.Migrations.AddSavedResetRedemptionToUpstreamIdentities do
  use Ecto.Migration

  def change do
    alter table(:upstream_identities) do
      add :saved_reset_auto_redeem_enabled, :boolean, null: false, default: false
      add :saved_reset_auto_redeem_min_blocked_minutes, :integer, null: false, default: 60
      add :saved_reset_auto_redeem_keep_credits, :integer, null: false, default: 0
    end

    create constraint(
             :upstream_identities,
             :upstream_identities_saved_reset_min_block_nonnegative_check,
             check: "saved_reset_auto_redeem_min_blocked_minutes >= 0"
           )

    create constraint(
             :upstream_identities,
             :upstream_identities_saved_reset_keep_credits_nonnegative_check,
             check: "saved_reset_auto_redeem_keep_credits >= 0"
           )
  end
end
