defmodule CodexPooler.Pools do
  @moduledoc """
  Pool lifecycle, routing, membership, and upstream assignment APIs.
  """

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
  alias CodexPooler.Audit
  alias CodexPooler.Events
  alias CodexPooler.Pools.{Authorization, Membership, Pool, Routing, RoutingSettings}
  alias CodexPooler.Repo

  @status_active "active"
  @status_disabled "disabled"
  @status_archived "archived"
  @management_pool_statuses [@status_active, @status_disabled, @status_archived]

  @type capability_key :: Authorization.capability_key()
  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type pool_ref :: Pool.t() | Ecto.UUID.t()
  @type pools_result :: {:ok, [Pool.t()]} | {:error, access_error()}
  @type pool_result :: {:ok, Pool.t()} | {:error, Ecto.Changeset.t() | access_error()}
  @type membership_result :: {:ok, Membership.t()} | {:error, Ecto.Changeset.t() | access_error()}
  @type routing_settings_result ::
          {:ok, RoutingSettings.t()} | {:error, Ecto.Changeset.t() | access_error()}
  @type capability_decision :: %{
          required(:actor_role) => String.t(),
          required(:capability) => String.t(),
          required(:pool_id) => Ecto.UUID.t() | nil
        }

  @spec capability(capability_key()) :: String.t()
  defdelegate capability(capability_key), to: Authorization

  @spec role(Authorization.role_key()) :: String.t()
  defdelegate role(role_key), to: Authorization

  @spec list_pools(term()) :: pools_result()
  def list_pools(%Scope{} = scope) do
    with {:ok, _decision} <- require_capability(scope, capability(:pool_operate)) do
      {:ok,
       Repo.all(from p in Pool, where: p.status == ^@status_active, order_by: [asc: p.created_at])}
    end
  end

  def list_pools(_scope),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec list_visible_pools(term()) :: [Pool.t()]
  def list_visible_pools(scope) do
    case list_pools(scope) do
      {:ok, pools} -> pools
      {:error, _reason} -> []
    end
  end

  @spec list_log_filter_pools(term()) :: [Pool.t()]
  def list_log_filter_pools(%Scope{} = scope) do
    case require_capability(scope, capability(:pool_operate)) do
      {:ok, _decision} ->
        Repo.all(
          from p in Pool,
            where: p.status in [^@status_active, ^@status_disabled],
            order_by: [asc: p.created_at]
        )

      {:error, _reason} ->
        []
    end
  end

  def list_log_filter_pools(_scope), do: []

  @spec list_pools_for_management(Scope.t()) :: {:ok, [Pool.t()]} | {:error, access_error()}
  def list_pools_for_management(%Scope{} = scope) do
    with {:ok, _decision} <- require_capability(scope, capability(:pool_manage)) do
      {:ok, Repo.all(from p in Pool, order_by: [asc: p.created_at])}
    end
  end

  def list_pools_for_management(_scope),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec can_manage_pools?(Scope.t()) :: boolean()
  def can_manage_pools?(%Scope{} = scope) do
    match?({:ok, _decision}, require_capability(scope, capability(:pool_manage)))
  end

  def can_manage_pools?(_scope), do: false

  @spec list_active_pools() :: [Pool.t()]
  def list_active_pools do
    Repo.all(from p in Pool, where: p.status == ^@status_active, order_by: [asc: p.created_at])
  end

  @spec get_pool(term()) :: Pool.t() | nil
  def get_pool(id) when is_binary(id), do: Repo.get(Pool, id)
  def get_pool(_id), do: nil

  @spec get_active_pool(term()) :: Pool.t() | nil
  def get_active_pool(id) when is_binary(id) do
    Repo.one(from p in Pool, where: p.id == ^id and p.status == ^@status_active)
  end

  def get_active_pool(_id), do: nil

  @spec get_routing_settings(pool_ref()) :: RoutingSettings.t() | nil
  defdelegate get_routing_settings(pool_or_id), to: Routing

  @spec v1_compatibility_enabled?(pool_ref()) :: boolean()
  defdelegate v1_compatibility_enabled?(pool_or_id), to: Routing

  @spec ensure_routing_settings(pool_ref()) :: RoutingSettings.t() | nil
  defdelegate ensure_routing_settings(pool_or_id), to: Routing

  @spec routing_settings_by_pool_ids([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => RoutingSettings.t()
        }
  defdelegate routing_settings_by_pool_ids(pool_ids), to: Routing

  @spec update_routing_settings(Scope.t(), Pool.t(), map(), keyword()) ::
          routing_settings_result()
  defdelegate update_routing_settings(scope, pool, attrs, opts \\ []), to: Routing

  @spec create_pool(Scope.t(), map(), keyword()) :: pool_result()
  def create_pool(scope, attrs, opts \\ [])

  def create_pool(%Scope{} = scope, attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, _decision} <- require_capability(scope, capability(:pool_manage)) do
      now = now()

      %Pool{}
      |> Pool.changeset(%{
        slug: Map.get(attrs, :slug) || Map.get(attrs, "slug"),
        name: Map.get(attrs, :name) || Map.get(attrs, "name"),
        status: Map.get(attrs, :status) || Map.get(attrs, "status") || @status_active,
        created_by_user_id: scope.user.id,
        created_at: now,
        updated_at: now
      })
      |> Repo.insert()
      |> tap(fn
        {:ok, pool} ->
          record_pool_audit_event(scope, "pool.create", pool)

          maybe_broadcast_pool_change(opts, pool, "pool_created")

        _result ->
          :ok
      end)
    end
  end

  def create_pool(_scope, _attrs, _opts),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec delete_pool(Scope.t(), pool_ref()) :: pool_result()
  def delete_pool(%Scope{} = scope, pool_or_id) do
    delete_archived_pool(scope, pool_or_id, nil)
  end

  def delete_pool(_scope, _pool_or_id),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec update_pool(Scope.t(), pool_ref(), map(), keyword()) :: pool_result()
  def update_pool(scope, pool_or_id, attrs, opts \\ [])

  def update_pool(%Scope{} = scope, pool_or_id, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with {:ok, _decision} <- require_capability(scope, capability(:pool_manage)),
         %Pool{} = pool <- normalize_pool(pool_or_id),
         {:ok, update_attrs} <- pool_update_attrs(attrs) do
      now = now()

      pool
      |> Pool.changeset(Map.put(update_attrs, :updated_at, now))
      |> Repo.update()
      |> tap(fn
        {:ok, pool} ->
          record_pool_audit_event(scope, "pool.update", pool, %{
            changed_fields: Map.keys(update_attrs) |> Enum.map(&to_string/1) |> Enum.sort(),
            name: pool.name,
            status: pool.status
          })

          maybe_broadcast_pool_change(opts, pool, "pool_updated")

        _result ->
          :ok
      end)
    else
      nil -> {:error, access_error(:pool_not_found, "pool was not found")}
      {:error, _reason} = error -> error
    end
  end

  def update_pool(_scope, _pool_or_id, _attrs, _opts),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec change_pool_status(Scope.t(), pool_ref(), String.t()) :: pool_result()
  def change_pool_status(%Scope{} = scope, pool_or_id, status) do
    with {:ok, _decision} <- require_capability(scope, capability(:pool_manage)),
         %Pool{} = pool <- normalize_pool(pool_or_id),
         {:ok, status} <- normalize_pool_status(status) do
      now = now()
      previous_status = pool.status

      pool
      |> Pool.changeset(%{
        status: status,
        disabled_at: pool_status_disabled_at(status),
        updated_at: now
      })
      |> Repo.update()
      |> tap(fn
        {:ok, pool} ->
          record_pool_audit_event(scope, "pool.status_update", pool, %{
            previous_status: previous_status,
            status: pool.status
          })

          Events.broadcast_pools(pool.id, "pool_status_updated", %{
            pool_id: pool.id,
            status: pool.status
          })

        _result ->
          :ok
      end)
    else
      nil -> {:error, access_error(:pool_not_found, "pool was not found")}
      {:error, _reason} = error -> error
    end
  end

  def change_pool_status(_scope, _pool_or_id, _status),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec delete_archived_pool(Scope.t(), pool_ref(), String.t() | nil) :: pool_result()
  def delete_archived_pool(%Scope{} = scope, pool_or_id, confirmation_slug) do
    with {:ok, _decision} <- require_capability(scope, capability(:pool_manage)),
         %Pool{} = pool <- normalize_pool(pool_or_id),
         :ok <- ensure_archived_pool(pool),
         :ok <- ensure_confirmation_slug(pool, confirmation_slug) do
      record_pool_audit_event(scope, "pool.delete", pool)

      Repo.delete(pool)
      |> tap(fn
        {:ok, deleted_pool} ->
          Events.broadcast_pools(deleted_pool.id, "pool_deleted", %{
            pool_id: deleted_pool.id,
            status: deleted_pool.status
          })

        _result ->
          :ok
      end)
    else
      nil -> {:error, access_error(:pool_not_found, "pool was not found")}
      {:error, _reason} = error -> error
    end
  end

  def delete_archived_pool(_scope, _pool_or_id, _confirmation_slug),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec create_membership(Scope.t(), map()) :: membership_result()
  def create_membership(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, _decision} <- require_capability(scope, capability(:pool_manage)) do
      now = now()

      %Membership{}
      |> Membership.changeset(%{
        user_id: Map.get(attrs, :user_id) || Map.get(attrs, "user_id"),
        role: Map.get(attrs, :role) || Map.get(attrs, "role"),
        status: Map.get(attrs, :status) || Map.get(attrs, "status") || @status_active,
        created_by_user_id: scope.user.id,
        created_at: now
      })
      |> Repo.insert()
    end
  end

  def create_membership(_scope, _attrs),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec create_instance_admin_membership(Scope.t() | User.t(), User.t()) :: membership_result()
  def create_instance_admin_membership(%Scope{} = scope, %User{} = user) do
    create_membership(scope, %{user_id: user.id, role: role(:instance_admin)})
  end

  def create_instance_admin_membership(%User{} = actor, %User{} = user) do
    actor
    |> Scope.for_user([])
    |> create_instance_admin_membership(user)
  end

  def create_instance_admin_membership(_actor, _user),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec list_active_memberships_for_user(term()) :: [Membership.t()]
  def list_active_memberships_for_user(user_id) when is_binary(user_id) do
    Repo.all(
      from m in Membership,
        where: m.user_id == ^user_id and m.status == ^@status_active,
        order_by: [asc: m.created_at]
    )
  end

  def list_active_memberships_for_user(_user_id), do: []

  @spec require_capability(Scope.t(), String.t(), keyword()) ::
          {:ok, capability_decision()} | {:error, access_error()}
  defdelegate require_capability(scope, capability, opts \\ []), to: Authorization

  @spec role_can?(String.t(), String.t()) :: boolean()
  defdelegate role_can?(role, capability), to: Authorization

  @spec access_error(atom(), String.t()) :: access_error()
  defdelegate access_error(code, message), to: Authorization

  defp normalize_pool(%Pool{} = pool), do: pool

  defp normalize_pool(id) when is_binary(id), do: Repo.get(Pool, id)

  defp normalize_pool(_id), do: nil

  defp pool_update_attrs(attrs) do
    with {:ok, status} <-
           normalize_optional_pool_status(Map.get(attrs, :status) || Map.get(attrs, "status")) do
      update_attrs =
        %{}
        |> maybe_put(:name, Map.get(attrs, :name) || Map.get(attrs, "name"))
        |> maybe_put(:status, status)

      update_attrs =
        case status do
          nil -> update_attrs
          _ -> Map.put(update_attrs, :disabled_at, pool_status_disabled_at(status))
        end

      {:ok, update_attrs}
    end
  end

  defp normalize_optional_pool_status(nil), do: {:ok, nil}

  defp normalize_optional_pool_status(status), do: normalize_pool_status(status)

  defp normalize_pool_status(status) when status in @management_pool_statuses,
    do: {:ok, status}

  defp normalize_pool_status(_status) do
    {:error, access_error(:invalid_status, "status must be active, disabled, or archived")}
  end

  defp pool_status_disabled_at(@status_active), do: nil
  defp pool_status_disabled_at(_status), do: now()

  defp ensure_archived_pool(%Pool{status: @status_archived}), do: :ok

  defp ensure_archived_pool(%Pool{}),
    do: {:error, access_error(:pool_not_archived, "pool must be archived before deletion")}

  defp ensure_confirmation_slug(%Pool{slug: slug}, slug), do: :ok

  defp ensure_confirmation_slug(%Pool{}, _confirmation_slug),
    do:
      {:error, access_error(:confirmation_mismatch, "confirmation slug did not match pool slug")}

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_broadcast_pool_change(opts, %Pool{} = pool, reason) do
    if Keyword.get(opts, :broadcast?, true) do
      Events.broadcast_pools(pool.id, reason, %{
        pool_id: pool.id,
        status: pool.status
      })
    end
  end

  defp record_pool_audit_event(scope, action, pool, details \\ %{})

  defp record_pool_audit_event(
         %Scope{user: %User{} = user},
         action,
         %Pool{} = pool,
         details
       ) do
    Audit.record_user_event(user, %{
      pool_id: pool.id,
      action: action,
      target_type: "pool",
      target_id: pool.id,
      details: Map.merge(pool_audit_details(pool), details)
    })
  end

  defp record_pool_audit_event(_scope, _action, _pool, _details), do: :ok

  defp pool_audit_details(%Pool{} = pool) do
    %{
      pool_id: pool.id,
      slug: pool.slug,
      name: pool.name,
      status: pool.status
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
