defmodule CodexPooler.Repo.Migrations.AddMcpToInstanceSettings do
  use Ecto.Migration

  def change do
    alter table(:instance_settings) do
      add :mcp, :map, null: false, default: fragment(~s('{"enabled": false}'::jsonb))
    end
  end
end
