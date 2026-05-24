defmodule CodexPooler.Repo.Migrations.AddRequestLogDisplaySnapshots do
  use Ecto.Migration

  def change do
    alter table(:requests) do
      add :upstream_account_email, :text, null: true
      add :upstream_account_plan_label, :text, null: true
      add :upstream_account_plan_family, :text, null: true
      add :reasoning_effort, :text, null: true
      add :service_tier, :text, null: true
      add :requested_service_tier, :text, null: true
      add :actual_service_tier, :text, null: true
    end
  end
end
