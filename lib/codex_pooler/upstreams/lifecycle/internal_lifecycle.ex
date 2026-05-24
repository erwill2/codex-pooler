defmodule CodexPooler.Upstreams.Lifecycle.InternalLifecycle do
  @moduledoc false

  alias CodexPooler.Pools.Pool

  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type assignment_result ::
          {:ok, PoolUpstreamAssignment.t()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type pool_account_result ::
          {:ok,
           %{
             required(:identity) => UpstreamIdentity.t(),
             required(:assignment) => PoolUpstreamAssignment.t()
           }}
          | {:error, Ecto.Changeset.t() | lifecycle_error()}

  @spec create_pending_pool_account(Pool.t(), map(), map()) :: pool_account_result()
  def create_pending_pool_account(%Pool{} = pool, identity_attrs, assignment_attrs)
      when is_map(identity_attrs) and is_map(assignment_attrs) do
    with {:ok, identity} <- IdentityLifecycle.create_upstream_identity(identity_attrs),
         {:ok, assignment} <-
           PoolAssignments.create_pool_assignment(pool, identity, assignment_attrs) do
      {:ok, %{identity: identity, assignment: assignment}}
    end
  end

  @spec update_pending_pool_account(
          UpstreamIdentity.t(),
          PoolUpstreamAssignment.t(),
          map(),
          map()
        ) ::
          pool_account_result()
  def update_pending_pool_account(
        %UpstreamIdentity{} = identity,
        %PoolUpstreamAssignment{} = assignment,
        identity_attrs,
        assignment_attrs
      )
      when is_map(identity_attrs) and is_map(assignment_attrs) do
    with {:ok, identity} <- IdentityLifecycle.update_upstream_identity(identity, identity_attrs),
         {:ok, assignment} <- PoolAssignments.update_pool_assignment(assignment, assignment_attrs) do
      {:ok, %{identity: identity, assignment: assignment}}
    end
  end

  @spec activate_verified_pool_account(
          UpstreamIdentity.t(),
          PoolUpstreamAssignment.t(),
          map(),
          map()
        ) :: pool_account_result()
  def activate_verified_pool_account(
        %UpstreamIdentity{} = identity,
        %PoolUpstreamAssignment{} = assignment,
        identity_attrs,
        assignment_attrs
      )
      when is_map(identity_attrs) and is_map(assignment_attrs) do
    with {:ok, identity} <-
           IdentityLifecycle.activate_upstream_identity_with_plan(identity, identity_attrs),
         {:ok, assignment} <-
           PoolAssignments.activate_pool_assignment(assignment, assignment_attrs) do
      {:ok, %{identity: identity, assignment: assignment}}
    end
  end

  @spec ensure_active_pool_assignment(Pool.t(), UpstreamIdentity.t(), map()) ::
          assignment_result()
  def ensure_active_pool_assignment(%Pool{} = pool, %UpstreamIdentity{} = identity, attrs)
      when is_map(attrs) do
    with {:ok, assignment} <- PoolAssignments.create_pool_assignment(pool, identity, attrs) do
      PoolAssignments.activate_pool_assignment(assignment, attrs)
    end
  end
end
