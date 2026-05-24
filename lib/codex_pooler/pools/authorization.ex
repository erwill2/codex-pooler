defmodule CodexPooler.Pools.Authorization do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools.{Membership, Pool}
  alias CodexPooler.Repo

  @role_instance_owner "instance_owner"
  @role_instance_admin "instance_admin"
  @status_active "active"

  @capability_pool_manage "pool.manage"
  @capability_pool_api_key_manage "pool_api_key.manage"
  @capability_pool_operate "pool.operate"

  @type capability_key :: :pool_manage | :pool_api_key_manage | :pool_operate
  @type role_key :: :instance_owner | :instance_admin
  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type capability_decision :: %{
          required(:actor_role) => String.t(),
          required(:capability) => String.t(),
          required(:pool_id) => Ecto.UUID.t() | nil
        }

  @spec capability(capability_key()) :: String.t()
  def capability(:pool_manage), do: @capability_pool_manage
  def capability(:pool_api_key_manage), do: @capability_pool_api_key_manage
  def capability(:pool_operate), do: @capability_pool_operate

  @spec role(role_key()) :: String.t()
  def role(:instance_owner), do: @role_instance_owner
  def role(:instance_admin), do: @role_instance_admin

  @spec role_values() :: [String.t()]
  def role_values, do: [@role_instance_owner, @role_instance_admin]

  @spec require_capability(Scope.t(), String.t(), keyword()) ::
          {:ok, capability_decision()} | {:error, access_error()}
  def require_capability(scope, capability, opts \\ [])

  # Reason: capability checks encode the node-admin role matrix in one place.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def require_capability(%Scope{user: %{id: user_id}}, capability, opts)
      when is_binary(user_id) do
    pool_id = Keyword.get(opts, :pool_id)
    actor_role = strongest_role_for_user(user_id)

    cond do
      is_nil(actor_role) ->
        {:error, access_error(:capability_denied, "only node admins can perform this capability")}

      is_nil(pool_id) and capability == @capability_pool_manage and
          actor_role == @role_instance_owner ->
        {:ok, decision(capability, actor_role, nil)}

      is_nil(pool_id) and capability == @capability_pool_operate and
          role_can?(actor_role, capability) ->
        {:ok, decision(capability, actor_role, nil)}

      is_nil(pool_id) ->
        {:error,
         access_error(
           :capability_denied,
           "only the instance owner can perform this global capability"
         )}

      not active_pool?(pool_id) ->
        {:error, access_error(:pool_not_found, "pool was not found")}

      role_can?(actor_role, capability) ->
        {:ok, decision(capability, actor_role, pool_id)}

      true ->
        {:error,
         access_error(
           :capability_denied,
           "the actor role cannot perform this capability in the requested scope"
         )}
    end
  end

  def require_capability(_scope, _capability, _opts),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec role_can?(String.t(), String.t()) :: boolean()
  def role_can?(@role_instance_owner, capability)
      when capability in [
             @capability_pool_manage,
             @capability_pool_api_key_manage,
             @capability_pool_operate
           ],
      do: true

  def role_can?(@role_instance_admin, capability)
      when capability in [@capability_pool_api_key_manage, @capability_pool_operate],
      do: true

  def role_can?(_role, _capability), do: false

  @spec access_error(atom(), String.t()) :: access_error()
  def access_error(code, message), do: %{code: code, message: message}

  defp strongest_role_for_user(user_id) do
    roles = user_id |> list_active_memberships_for_user() |> Enum.map(& &1.role)

    Enum.find(roles, &(&1 == @role_instance_owner)) ||
      Enum.find(roles, &(&1 == @role_instance_admin))
  end

  defp list_active_memberships_for_user(user_id) do
    Repo.all(
      from membership in Membership,
        where: membership.user_id == ^user_id and membership.status == ^@status_active,
        order_by: [asc: membership.created_at]
    )
  end

  defp active_pool?(pool_id) do
    Repo.exists?(
      from pool in Pool,
        where: pool.id == ^pool_id and pool.status == ^@status_active
    )
  end

  defp decision(capability, role, pool_id),
    do: %{capability: capability, actor_role: role, pool_id: pool_id}
end
