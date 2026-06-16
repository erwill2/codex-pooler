defmodule CodexPooler.MixTasks.TestDatabaseLockTest do
  use ExUnit.Case, async: false

  alias CodexPooler.MixTasks.TestDatabaseLock
  alias CodexPooler.Repo

  @lock_namespace "codex_pooler_test_runner"
  @lock_database "postgres"
  @lock_wait_attempts 50
  @connection_keys [
    :after_connect,
    :connect_timeout,
    :hostname,
    :password,
    :parameters,
    :port,
    :socket_dir,
    :socket_options,
    :ssl,
    :ssl_opts,
    :timeout,
    :types,
    :url,
    :username
  ]

  test "serializes concurrent callers for the configured test database" do
    parent = self()
    repo_config = Keyword.put(Repo.config(), :database, "codex_pooler_test_lock_regression")
    observer = start_lock_observer!(repo_config)

    on_exit(fn -> stop_lock_observer(observer) end)

    first =
      Task.async(fn ->
        TestDatabaseLock.with_lock!(repo_config, fn ->
          send(parent, :first_locked)

          receive do
            :release_first -> :first_released
          after
            5_000 -> raise "timed out waiting to release first lock holder"
          end
        end)
      end)

    assert_receive :first_locked, 5_000

    second =
      Task.async(fn ->
        send(parent, :second_entering_lock)

        TestDatabaseLock.with_lock!(repo_config, fn ->
          send(parent, :second_locked)
          :second_released
        end)
      end)

    assert_receive :second_entering_lock, 5_000
    assert_advisory_lock_waiter!(observer, repo_config)

    send(first.pid, :release_first)

    assert Task.await(first) == :first_released
    assert Task.await(second) == :second_released
    assert_receive :second_locked
  end

  defp assert_advisory_lock_waiter!(conn, repo_config, attempts \\ @lock_wait_attempts)

  defp assert_advisory_lock_waiter!(conn, repo_config, attempts) when attempts > 0 do
    if advisory_lock_waiter?(conn, repo_config) do
      :ok
    else
      receive do
      after
        20 -> assert_advisory_lock_waiter!(conn, repo_config, attempts - 1)
      end
    end
  end

  defp assert_advisory_lock_waiter!(_conn, repo_config, 0) do
    flunk(
      "expected a PostgreSQL advisory lock waiter for #{Keyword.fetch!(repo_config, :database)}"
    )
  end

  defp advisory_lock_waiter?(conn, repo_config) do
    %{rows: [[waiting?]]} =
      Postgrex.query!(
        conn,
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_locks
          WHERE locktype = 'advisory'
            AND classid = hashtext($1)::oid
            AND objid = hashtext($2)::oid
            AND NOT granted
        )
        """,
        [@lock_namespace, Keyword.fetch!(repo_config, :database)]
      )

    waiting?
  end

  defp start_lock_observer!(repo_config) do
    {:ok, _started} = Application.ensure_all_started(:postgrex)

    repo_config
    |> Keyword.take(@connection_keys)
    |> Keyword.put(:database, lock_database(repo_config))
    |> Postgrex.start_link()
    |> case do
      {:ok, conn} -> conn
      {:error, _reason} -> raise "failed to start test database lock observer"
    end
  end

  defp lock_database(repo_config) do
    Keyword.get(repo_config, :maintenance_database) || @lock_database
  end

  defp stop_lock_observer(conn) do
    if Process.alive?(conn) do
      GenServer.stop(conn)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end
end
