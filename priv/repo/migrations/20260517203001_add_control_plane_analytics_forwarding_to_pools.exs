defmodule CodexPooler.Repo.Migrations.AddControlPlaneAnalyticsForwardingToPools do
  use Ecto.Migration

  def change do
    alter table(:pool_routing_settings) do
      add :control_plane_analytics_forwarding_enabled, :boolean, null: false, default: true
    end

    execute(
      "UPDATE pool_routing_settings SET control_plane_analytics_forwarding_enabled = TRUE WHERE control_plane_analytics_forwarding_enabled IS NULL",
      "UPDATE pool_routing_settings SET control_plane_analytics_forwarding_enabled = TRUE"
    )
  end
end
