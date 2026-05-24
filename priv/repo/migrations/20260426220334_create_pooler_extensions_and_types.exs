defmodule CodexPooler.Repo.Migrations.CreatePoolerExtensionsAndTypes do
  use Ecto.Migration

  @monolithic_migration_version "20260426220333"

  def up do
    unless monolithic_migration_applied?() do
      execute_statements(~S"""
      CREATE EXTENSION IF NOT EXISTS pgcrypto;

      CREATE TYPE public.oban_job_state AS ENUM (
      'available',
      'suspended',
      'scheduled',
      'executing',
      'retryable',
      'completed',
      'discarded',
      'cancelled'
      );
      """)
    end
  end

  def down do
    unless monolithic_migration_applied?() do
      execute_statements(~S"""
      DROP TYPE IF EXISTS public.oban_job_state;
      DROP EXTENSION IF EXISTS pgcrypto;
      """)
    end
  end

  defp monolithic_migration_applied? do
    %{num_rows: rows} =
      repo().query!("SELECT 1 FROM schema_migrations WHERE version::text = $1", [
        @monolithic_migration_version
      ])

    rows > 0
  end

  defp execute_statements(sql) do
    sql
    |> statements()
    |> Enum.each(&execute/1)
  end

  defp statements(sql) do
    sql
    |> String.split(~r/; *\n/,
      trim: true
    )
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
