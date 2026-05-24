defmodule CodexPooler.Access.APIKeys do
  @moduledoc false

  alias CodexPooler.Access.APIKey

  alias CodexPooler.Access.APIKeys.{
    Assignment,
    AuditLog,
    Authentication,
    Errors,
    Material,
    Notifications,
    Policy,
    PolicyPersistence,
    PolicyUpdate,
    Queries
  }

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Authorization, as: PoolAuthorization
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @status_active "active"
  @status_paused "paused"
  @status_revoked "revoked"
  @policy_denial_precedence [
    :api_key_missing,
    :api_key_disabled,
    :api_key_policy_malformed,
    :model_not_allowed,
    :quota_unavailable,
    :quota_exhausted,
    :no_eligible_upstream
  ]

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type auth_context :: %{
          required(:api_key) => APIKey.t(),
          required(:pool) => Pool.t(),
          required(:api_key_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:key_prefix) => String.t()
        }
  @type api_key_result :: {:ok, map()} | {:error, Ecto.Changeset.t() | access_error()}
  @type policy_result :: {:ok, map()} | {:error, atom() | access_error()}

  @spec create_api_key(Scope.t(), Pool.t() | Ecto.UUID.t(), map()) ::
          api_key_result()
  def create_api_key(scope, pool_or_id, attrs \\ %{})

  def create_api_key(%Scope{} = scope, pool_or_id, attrs) when is_map(attrs) do
    create_api_key_lifecycle(scope, pool_or_id, attrs)
  end

  def create_api_key(_scope, _pool_or_id, _attrs),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  defp create_api_key_lifecycle(%Scope{} = scope, pool_or_id, attrs) do
    with %Pool{} = pool <- normalize_pool(pool_or_id),
         {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: pool.id
           ),
         {:ok, expires_at} <-
           parse_expires_at(Map.get(attrs, :expires_at) || Map.get(attrs, "expires_at")),
         {:ok, policy_attrs} <- Policy.normalize_attrs(scope, pool.id, attrs),
         {:ok, policy_inputs} <- Policy.normalize_inputs(attrs) do
      now = now()
      {key_prefix, raw_key, key_hash} = Material.generate()

      api_key_attrs =
        policy_attrs
        |> Map.merge(%{
          pool_id: pool.id,
          display_name: Map.get(attrs, :display_name) || Map.get(attrs, "display_name"),
          key_prefix: key_prefix,
          key_hash: key_hash,
          status: Map.get(attrs, :status) || Map.get(attrs, "status") || @status_active,
          expires_at: expires_at,
          metadata: Policy.input(attrs, [:metadata, "metadata"]) || %{},
          created_by_user_id: scope.user.id,
          created_at: now
        })

      PolicyPersistence.create_api_key(api_key_attrs, policy_inputs, raw_key, now)
      |> PolicyPersistence.normalize_transaction_result()
      |> AuditLog.audit_api_key_change(
        scope,
        "api_key.create",
        &AuditLog.api_key_policy_audit_details/1
      )
      |> Notifications.notify_api_key_change("api_key_created")
    else
      nil -> {:error, Errors.access_error(:pool_not_found, "pool was not found")}
      {:error, _reason} = error -> error
    end
  end

  @spec list_api_keys(Scope.t()) :: {:ok, [APIKey.t()]} | {:error, access_error()}
  defdelegate list_api_keys(scope), to: Queries

  @spec count_api_keys_by_pool_ids([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => non_neg_integer()
        }
  defdelegate count_api_keys_by_pool_ids(pool_ids), to: Queries

  @spec api_key_ids_for_pool(Pool.t()) :: [Ecto.UUID.t()]
  defdelegate api_key_ids_for_pool(pool), to: Queries

  @spec assign_api_keys_to_pool(
          Scope.t(),
          Pool.t() | Ecto.UUID.t(),
          [Ecto.UUID.t()]
        ) ::
          :ok | {:error, Ecto.Changeset.t() | access_error()}
  defdelegate assign_api_keys_to_pool(scope, pool_or_id, api_key_ids), to: Assignment

  @spec list_api_keys_with_policy(Scope.t()) :: {:ok, [map()]} | {:error, access_error()}
  defdelegate list_api_keys_with_policy(scope), to: Queries

  @spec list_api_keys(Scope.t(), Pool.t() | Ecto.UUID.t()) ::
          {:ok, [APIKey.t()]} | {:error, access_error()}
  defdelegate list_api_keys(scope, pool_or_id), to: Queries

  @spec get_api_key(Scope.t(), Ecto.UUID.t()) :: {:ok, APIKey.t()} | {:error, access_error()}
  defdelegate get_api_key(scope, api_key_id), to: Queries

  @spec get_api_key_with_policy(Scope.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, access_error()}
  defdelegate get_api_key_with_policy(scope, api_key_id), to: Queries

  @spec update_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t(), map()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  def update_api_key(%Scope{} = scope, %APIKey{} = api_key, attrs) when is_map(attrs) do
    with {:ok, target_pool_id} <- authorize_api_key_update(scope, api_key, attrs) do
      api_key
      |> update_api_key_record(api_key_update_attrs(attrs, target_pool_id))
      |> Notifications.notify_api_key_change("api_key_updated", api_key.pool_id)
      |> AuditLog.audit_api_key_change(scope, "api_key.update", fn updated ->
        AuditLog.api_key_update_audit_details(updated, api_key, attrs)
      end)
    end
  end

  def update_api_key(%Scope{} = scope, api_key_id, attrs) when is_binary(api_key_id) do
    with {:ok, api_key} <- get_api_key(scope, api_key_id) do
      update_api_key(scope, api_key, attrs)
    end
  end

  def update_api_key(_scope, _api_key, _attrs),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec update_api_key_with_policy(
          Scope.t(),
          APIKey.t() | Ecto.UUID.t(),
          map()
        ) :: api_key_result()
  defdelegate update_api_key_with_policy(scope, api_key, attrs), to: PolicyUpdate

  defp authorize_api_key_update(%Scope{} = scope, %APIKey{} = api_key, attrs) do
    target_pool_id = Map.get(attrs, :pool_id) || Map.get(attrs, "pool_id") || api_key.pool_id

    with %Pool{} = _target_pool <- normalize_pool(target_pool_id),
         {:ok, _existing_decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: api_key.pool_id
           ),
         {:ok, _target_decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: target_pool_id
           ) do
      {:ok, target_pool_id}
    else
      nil -> {:error, Errors.access_error(:pool_not_found, "pool was not found")}
      {:error, _reason} = error -> error
    end
  end

  defp update_api_key_record(api_key, update_attrs) do
    api_key
    |> APIKey.changeset(update_attrs)
    |> Repo.update()
  end

  @spec pause_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  def pause_api_key(%Scope{} = scope, %APIKey{} = api_key),
    do: change_api_key_status(scope, api_key, @status_active, @status_paused)

  def pause_api_key(%Scope{} = scope, api_key_id) when is_binary(api_key_id),
    do: APIKey |> Repo.get(api_key_id) |> then(&pause_api_key(scope, &1))

  def pause_api_key(%Scope{}, _api_key),
    do: {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

  def pause_api_key(_scope, _api_key),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec resume_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  def resume_api_key(%Scope{} = scope, %APIKey{} = api_key),
    do: change_api_key_status(scope, api_key, @status_paused, @status_active)

  def resume_api_key(%Scope{} = scope, api_key_id) when is_binary(api_key_id),
    do: APIKey |> Repo.get(api_key_id) |> then(&resume_api_key(scope, &1))

  def resume_api_key(%Scope{}, _api_key),
    do: {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

  def resume_api_key(_scope, _api_key),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec rotate_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          api_key_result()
  def rotate_api_key(%Scope{} = scope, %APIKey{} = api_key) do
    with {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: api_key.pool_id
           ),
         :ok <- ensure_api_key_rotatable(api_key) do
      {key_prefix, raw_key, key_hash} = Material.generate()

      api_key
      |> APIKey.changeset(%{key_prefix: key_prefix, key_hash: key_hash})
      |> Repo.update()
      |> case do
        {:ok, rotated_key} -> {:ok, %{api_key: rotated_key, raw_key: raw_key}}
        {:error, _changeset} = error -> error
      end
      |> Notifications.notify_api_key_change("api_key_rotated")
      |> AuditLog.audit_api_key_change(scope, "api_key.rotate", fn _result ->
        %{previous_key_prefix: api_key.key_prefix}
      end)
    end
  end

  def rotate_api_key(%Scope{} = scope, api_key_id) when is_binary(api_key_id),
    do: APIKey |> Repo.get(api_key_id) |> then(&rotate_api_key(scope, &1))

  def rotate_api_key(%Scope{}, _api_key),
    do: {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

  def rotate_api_key(_scope, _api_key),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec revoke_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  def revoke_api_key(%Scope{} = scope, %APIKey{} = api_key) do
    with {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: api_key.pool_id
           ) do
      if api_key.status == @status_revoked do
        {:ok, api_key}
      else
        api_key
        |> APIKey.changeset(%{status: @status_revoked, revoked_at: now()})
        |> Repo.update()
        |> Notifications.notify_api_key_change("api_key_revoked")
        |> AuditLog.audit_api_key_status_change(
          scope,
          "api_key.revoke",
          api_key.status,
          @status_revoked
        )
      end
    end
  end

  def revoke_api_key(%Scope{} = scope, api_key_id) when is_binary(api_key_id),
    do: APIKey |> Repo.get(api_key_id) |> then(&revoke_api_key(scope, &1))

  def revoke_api_key(%Scope{}, _api_key),
    do: {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

  def revoke_api_key(_scope, _api_key),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec delete_api_key(Scope.t(), APIKey.t() | Ecto.UUID.t()) ::
          {:ok, APIKey.t()} | {:error, Ecto.Changeset.t() | access_error()}
  def delete_api_key(%Scope{} = scope, %APIKey{} = api_key) do
    with {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: api_key.pool_id
           ) do
      Repo.delete(api_key)
      |> Notifications.notify_api_key_change("api_key_deleted")
      |> AuditLog.audit_api_key_change(scope, "api_key.delete")
    end
  end

  def delete_api_key(%Scope{} = scope, api_key_id) when is_binary(api_key_id),
    do: APIKey |> Repo.get(api_key_id) |> then(&delete_api_key(scope, &1))

  def delete_api_key(%Scope{}, _api_key),
    do: {:error, Errors.access_error(:api_key_not_found, "api key was not found")}

  def delete_api_key(_scope, _api_key),
    do: {:error, Errors.access_error(:invalid_request, "user scope is required")}

  @spec authenticate_api_key(term()) :: {:ok, auth_context()} | {:error, access_error()}
  defdelegate authenticate_api_key(raw_key), to: Authentication

  @spec authenticate_authorization_header(term()) ::
          {:ok, auth_context()} | {:error, access_error()}
  defdelegate authenticate_authorization_header(header), to: Authentication

  @spec authenticate_v1_authorization_header(term()) ::
          {:ok, auth_context()} | {:error, access_error()}
  defdelegate authenticate_v1_authorization_header(header), to: Authentication

  @spec authenticate_v1_api_key(term()) :: {:ok, auth_context()} | {:error, access_error()}
  defdelegate authenticate_v1_api_key(raw_key), to: Authentication

  @spec policy_denial_precedence() :: [atom()]
  def policy_denial_precedence, do: @policy_denial_precedence

  @spec normalize_api_key_policy(term()) :: policy_result()
  def normalize_api_key_policy(policy), do: Policy.normalize(policy)

  @spec authorize_api_key_policy(term(), map()) :: {:ok, map()} | {:error, atom()}
  def authorize_api_key_policy(api_key_or_policy, attrs \\ %{})

  def authorize_api_key_policy(api_key_or_policy, attrs) when is_map(attrs) do
    Policy.authorize(api_key_or_policy, attrs)
  end

  def authorize_api_key_policy(_api_key_or_policy, _attrs),
    do: {:error, :api_key_policy_malformed}

  @spec hash_api_key_secret(binary()) :: binary()
  defdelegate hash_api_key_secret(secret), to: Authentication

  @spec access_error(atom(), String.t()) :: access_error()
  defdelegate access_error(code, message), to: Errors

  defp change_api_key_status(%Scope{} = scope, %APIKey{} = api_key, from_status, to_status) do
    with {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_api_key_manage),
             pool_id: api_key.pool_id
           ) do
      cond do
        api_key.status == @status_revoked ->
          {:error, Errors.access_error(:api_key_revoked, "revoked api keys cannot be changed")}

        api_key.status == to_status ->
          {:ok, api_key}

        api_key.status != from_status ->
          {:error,
           Errors.access_error(
             :api_key_status_conflict,
             "api key is not in a status that allows this action"
           )}

        true ->
          api_key
          |> APIKey.changeset(%{status: to_status})
          |> Repo.update()
          |> Notifications.notify_api_key_change("api_key_status_updated")
          |> AuditLog.audit_api_key_status_change(
            scope,
            AuditLog.api_key_status_audit_action(to_status),
            api_key.status,
            to_status
          )
      end
    end
  end

  defp ensure_api_key_rotatable(%APIKey{status: @status_revoked}),
    do: {:error, Errors.access_error(:api_key_revoked, "revoked api keys cannot be rotated")}

  defp ensure_api_key_rotatable(%APIKey{}), do: :ok

  defp api_key_update_attrs(attrs, target_pool_id) do
    attrs
    |> Map.take([
      :display_name,
      :status,
      :expires_at,
      :allowed_model_identifiers,
      :metadata,
      "display_name",
      "status",
      "expires_at",
      "allowed_model_identifiers",
      "metadata"
    ])
    |> Map.put(:pool_id, target_pool_id)
  end

  defp normalize_pool(%Pool{} = pool), do: pool
  defp normalize_pool(id) when is_binary(id), do: Pools.get_active_pool(id)
  defp normalize_pool(_pool_or_id), do: nil

  defp parse_expires_at(nil), do: {:ok, nil}
  defp parse_expires_at(""), do: {:ok, nil}

  defp parse_expires_at(%DateTime{} = expires_at),
    do: {:ok, DateTime.truncate(expires_at, :microsecond)}

  defp parse_expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, _offset} ->
        {:ok, DateTime.truncate(expires_at, :microsecond)}

      {:error, _reason} ->
        {:error, Errors.access_error(:invalid_request, "expires_at must be an RFC3339 timestamp")}
    end
  end

  defp parse_expires_at(_value),
    do: {:error, Errors.access_error(:invalid_request, "expires_at must be an RFC3339 timestamp")}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
