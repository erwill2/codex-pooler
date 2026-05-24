defmodule CodexPooler.Repo.Migrations.AddDevelopmentToInstanceSettings do
  use Ecto.Migration

  def change do
    alter table(:instance_settings) do
      add :development, :map,
        null: false,
        default: fragment(~s('{"impeccable_live_enabled": false}'::jsonb))
    end
  end
end
