defmodule CodexPooler.Gateway.Persistence.RuntimeCleanup do
  @moduledoc """
  Cleanup helpers for expired gateway runtime persistence records.
  """

  import Ecto.Query

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    IdempotencyKey
  }

  alias CodexPooler.Repo

  @spec cleanup_expired(DateTime.t()) :: {:ok, map()} | {:error, term()}
  def cleanup_expired(now \\ now()) do
    now = DateTime.truncate(now, :microsecond)
    active_alias_status = BridgeSessionAlias.active_status()
    active_lease_status = BridgeOwnerLease.active_status()
    expired_alias_status = BridgeSessionAlias.expired_status()
    expired_lease_status = BridgeOwnerLease.expired_status()
    expired_idempotency_status = IdempotencyKey.expired_status()
    expirable_idempotency_statuses = IdempotencyKey.expirable_statuses()

    Repo.transaction(fn ->
      {expired_aliases, _} =
        BridgeSessionAlias
        |> where(
          [alias_record],
          alias_record.status == ^active_alias_status and alias_record.expires_at <= ^now
        )
        |> Repo.update_all(set: [status: expired_alias_status, updated_at: now])

      {expired_leases, _} =
        BridgeOwnerLease
        |> where([lease], lease.status == ^active_lease_status and lease.expires_at <= ^now)
        |> Repo.update_all(set: [status: expired_lease_status, released_at: now, updated_at: now])

      {expired_idempotency_keys, _} =
        IdempotencyKey
        |> where(
          [key],
          key.status in ^expirable_idempotency_statuses and key.expires_at <= ^now
        )
        |> Repo.update_all(set: [status: expired_idempotency_status, updated_at: now])

      %{
        expired_aliases: expired_aliases,
        expired_owner_leases: expired_leases,
        expired_idempotency_keys: expired_idempotency_keys
      }
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
