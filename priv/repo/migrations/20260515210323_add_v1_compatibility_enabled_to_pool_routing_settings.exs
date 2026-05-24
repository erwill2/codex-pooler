defmodule CodexPooler.Repo.Migrations.AddV1CompatibilityEnabledToPoolRoutingSettings do
  use Ecto.Migration

  def change do
    alter table(:pool_routing_settings) do
      add :v1_compatibility_enabled, :boolean, null: false, default: true
    end

    execute(
      "UPDATE pool_routing_settings SET v1_compatibility_enabled = TRUE WHERE v1_compatibility_enabled IS NULL",
      "UPDATE pool_routing_settings SET v1_compatibility_enabled = TRUE"
    )
  end
end
