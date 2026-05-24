defmodule CodexPooler.Repo.Migrations.AddUpstreamAccountLabelToRequests do
  use Ecto.Migration

  def change do
    alter table(:requests) do
      add :upstream_account_label, :text, null: true
    end

    execute(
      """
      UPDATE requests
      SET upstream_account_label = upstream_account_email
      WHERE upstream_account_label IS NULL
        AND upstream_account_email IS NOT NULL
      """,
      "UPDATE requests SET upstream_account_label = NULL"
    )

    execute(
      """
      UPDATE requests
      SET upstream_account_email = NULL
      WHERE upstream_account_email IS NOT NULL
        AND upstream_account_email NOT LIKE '%@%'
      """,
      "SELECT 1"
    )
  end
end
