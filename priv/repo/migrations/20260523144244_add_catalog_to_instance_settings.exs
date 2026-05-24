defmodule CodexPooler.Repo.Migrations.AddCatalogToInstanceSettings do
  use Ecto.Migration

  def change do
    alter table(:instance_settings) do
      add :catalog, :map,
        null: false,
        default:
          fragment(
            ~s('{"openai_pricing_url": "https://s3.icorete.ch/openai-json-pricing/pricing.json"}'::jsonb)
          )
    end
  end
end
