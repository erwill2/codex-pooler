defmodule Mix.Tasks.CodexPooler.Test do
  @moduledoc """
  Runs the test suite while holding the shared test database lock.
  """

  use Mix.Task

  alias CodexPooler.MixTasks.TestDatabaseLock
  alias Mix.Tasks.Test

  @shortdoc "Runs ecto setup and tests under the shared test database lock"

  @impl Mix.Task
  def run(args) do
    TestDatabaseLock.with_lock!(CodexPooler.Repo.config(), fn ->
      Mix.Task.run("ecto.create", ["--quiet"])
      Mix.Task.run("ecto.migrate", ["--quiet"])
      Test.run(args)
    end)
  end
end
