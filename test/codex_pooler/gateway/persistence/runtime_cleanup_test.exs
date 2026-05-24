defmodule CodexPooler.Gateway.Persistence.RuntimeCleanupTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    IdempotencyKey,
    RuntimeCleanup
  }

  test "expires only cleanup-eligible runtime records past their ttl" do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    past = DateTime.add(now, -1, :second)
    future = DateTime.add(now, 60, :second)
    session = session_fixture(pool, api_key, assignment, now)

    expired_alias =
      alias_fixture(pool, api_key, session,
        status: BridgeSessionAlias.active_status(),
        expires_at: past,
        token: "expired-alias"
      )

    future_alias =
      alias_fixture(pool, api_key, session,
        status: BridgeSessionAlias.active_status(),
        expires_at: future,
        token: "future-alias"
      )

    expired_lease =
      lease_fixture(pool, api_key, assignment, session,
        status: BridgeOwnerLease.active_status(),
        expires_at: past,
        now: now
      )

    in_progress_key =
      idempotency_key_fixture(pool, api_key,
        status: IdempotencyKey.in_progress_status(),
        expires_at: past,
        token: "in-progress-key"
      )

    succeeded_key =
      idempotency_key_fixture(pool, api_key,
        status: IdempotencyKey.succeeded_status(),
        expires_at: past,
        token: "succeeded-key"
      )

    failed_key =
      idempotency_key_fixture(pool, api_key,
        status: IdempotencyKey.failed_status(),
        expires_at: past,
        token: "failed-key"
      )

    assert {:ok,
            %{
              expired_aliases: 1,
              expired_owner_leases: 1,
              expired_idempotency_keys: 2
            }} = RuntimeCleanup.cleanup_expired(now)

    assert Repo.reload!(expired_alias).status == BridgeSessionAlias.expired_status()
    assert Repo.reload!(future_alias).status == BridgeSessionAlias.active_status()
    assert Repo.reload!(expired_lease).status == BridgeOwnerLease.expired_status()
    assert Repo.reload!(in_progress_key).status == IdempotencyKey.expired_status()
    assert Repo.reload!(succeeded_key).status == IdempotencyKey.expired_status()
    assert Repo.reload!(failed_key).status == IdempotencyKey.failed_status()
  end

  defp session_fixture(pool, api_key, assignment, now) do
    %CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: "session-#{System.unique_integer([:positive])}",
      pool_upstream_assignment_id: assignment.id,
      status: "active",
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp alias_fixture(pool, api_key, session, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    token = Keyword.fetch!(attrs, :token)

    %BridgeSessionAlias{
      codex_session_id: session.id,
      pool_id: pool.id,
      api_key_id: api_key.id,
      alias_kind: "session_header",
      alias_hash: hash_token(token),
      alias_preview: String.slice(token, 0, 8),
      status: Keyword.fetch!(attrs, :status),
      expires_at: Keyword.fetch!(attrs, :expires_at),
      metadata: %{},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp lease_fixture(pool, api_key, assignment, session, attrs) do
    now = Keyword.fetch!(attrs, :now)

    %BridgeOwnerLease{
      codex_session_id: session.id,
      pool_id: pool.id,
      api_key_id: api_key.id,
      pool_upstream_assignment_id: assignment.id,
      owner_instance_id: "runtime-cleanup-test",
      lease_token: Ecto.UUID.generate(),
      status: Keyword.fetch!(attrs, :status),
      acquired_at: now,
      renewed_at: now,
      expires_at: Keyword.fetch!(attrs, :expires_at),
      metadata: %{},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp idempotency_key_fixture(pool, api_key, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    token = Keyword.fetch!(attrs, :token)

    %IdempotencyKey{
      pool_id: pool.id,
      api_key_id: api_key.id,
      scope: "runtime-cleanup-test",
      key_hash: hash_token(token),
      status: Keyword.fetch!(attrs, :status),
      expires_at: Keyword.fetch!(attrs, :expires_at),
      response_metadata: %{},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)
end
