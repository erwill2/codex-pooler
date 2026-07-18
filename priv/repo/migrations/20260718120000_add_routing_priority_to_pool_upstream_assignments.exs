defmodule CodexPooler.Repo.Migrations.AddRoutingPriorityToPoolUpstreamAssignments do
  use Ecto.Migration

  def change do
    alter table(:pool_upstream_assignments) do
      add :routing_priority, :integer, null: false, default: 100
    end

    create constraint(
             :pool_upstream_assignments,
             :pool_upstream_assignments_routing_priority_check,
             check: "routing_priority >= 1 AND routing_priority <= 10000"
           )
  end
end
