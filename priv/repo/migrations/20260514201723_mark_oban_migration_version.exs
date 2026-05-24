defmodule CodexPooler.Repo.Migrations.MarkObanMigrationVersion do
  use Ecto.Migration

  def up do
    execute "COMMENT ON TABLE public.oban_jobs IS '14'"
  end

  def down do
    execute "COMMENT ON TABLE public.oban_jobs IS NULL"
  end
end
