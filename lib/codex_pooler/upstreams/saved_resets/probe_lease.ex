defmodule CodexPooler.Upstreams.SavedResets.ProbeLease do
  @moduledoc """
  The one-shot, cross-node probe claim for a pending saved-reset redemption.

  After a credit is consumed but the account quota window is omitted by the
  provider, exactly one request is allowed to route to that identity as a guarded
  probe. This module makes that claim under the identity's `FOR UPDATE` lock so
  that competing replicas cannot both probe: the first correlation token to claim
  wins, everyone else is rejected before dispatch.

  The claim is irreversible. If the claiming request fails (network, 5xx,
  cancellation), the probe is NOT handed to another request — recovery then comes
  only from fresh provider evidence (see `Convergence`) or the bounded-window
  expiry. This guarantees a consumed credit can never trigger a second
  consumption or a second account's probe.
  """

  import Ecto.Query

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @type claim_result :: {:ok, :claimed} | {:error, :unavailable | :not_found}

  @doc """
  Attempts to claim the probe for `token` on the identity's pending redemption,
  matching the expected `generation` and `attempt_id` (compare-and-set).

  Returns `{:ok, :claimed}` for the winning token (idempotent for the same token)
  and `{:error, :unavailable}` when the probe is already claimed by another
  token, the redemption is not pending, or the window has elapsed.
  """
  @spec claim(UpstreamIdentity.t() | Ecto.UUID.t(), integer(), term(), String.t()) ::
          claim_result()
  @spec claim(UpstreamIdentity.t() | Ecto.UUID.t(), integer(), term(), String.t(), DateTime.t()) ::
          claim_result()
  def claim(identity_or_id, generation, attempt_id, token, now \\ now())
      when is_binary(token) do
    case identity_id(identity_or_id) do
      nil ->
        {:error, :not_found}

      id ->
        Repo.transaction(fn -> claim_locked(id, generation, attempt_id, token, now) end)
        |> case do
          {:ok, :claimed} -> {:ok, :claimed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp claim_locked(id, generation, attempt_id, token, now) do
    identity = lock_identity!(id)
    redemption = (identity.metadata || %{})["saved_reset_redemption"]

    cond do
      RedemptionLifecycle.holds_probe?(redemption, token) ->
        :claimed

      claimable?(redemption, generation, attempt_id, now) ->
        write_probe!(identity, redemption, token, now)
        :claimed

      true ->
        Repo.rollback(:unavailable)
    end
  end

  defp claimable?(redemption, generation, attempt_id, now) do
    RedemptionLifecycle.probe_claimable?(redemption, now) and
      Map.get(redemption, "generation") == generation and
      Map.get(redemption, "attempt_id") == attempt_id
  end

  defp write_probe!(identity, redemption, token, now) do
    updated =
      Map.put(redemption, "probe", %{
        "token" => token,
        "claimed_at" => DateTime.to_iso8601(now)
      })

    identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.put(identity.metadata || %{}, "saved_reset_redemption", updated),
      updated_at: now
    })
    |> Repo.update!()
  end

  defp lock_identity!(id) do
    Repo.one!(
      from identity in UpstreamIdentity,
        where: identity.id == ^id,
        lock: "FOR UPDATE"
    )
  end

  defp identity_id(%UpstreamIdentity{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_identity_or_id), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
