defmodule CodexPooler.Repo.Migrations.RemoveInertRoutingSettingsFields do
  use Ecto.Migration

  def change do
    alter table(:pool_routing_settings) do
      remove :prefer_early_reset, :boolean, null: false, default: false
      remove :allow_cooldown_fallback, :boolean, null: false, default: false
    end
  end
end
