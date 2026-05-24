defmodule CodexPooler.Upstreams.Lifecycle.IdentityLifecycle do
  @moduledoc false

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @active UpstreamIdentity.active_status()
  @disabled UpstreamIdentity.disabled_status()
  @pending UpstreamIdentity.pending_status()

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()
  @type identity_result ::
          {:ok, UpstreamIdentity.t()} | {:error, Ecto.Changeset.t() | lifecycle_error()}

  @spec create_upstream_identity(map()) :: identity_result()
  def create_upstream_identity(attrs) when is_map(attrs) do
    create_identity(attrs, plan_metadata: :ignore)
  end

  @spec activate_upstream_identity_with_plan(identity_ref(), map()) :: identity_result()
  def activate_upstream_identity_with_plan(identity_or_id, attrs \\ %{}) do
    activate_identity(identity_or_id, attrs, plan_metadata: :allow)
  end

  @spec update_upstream_identity(UpstreamIdentity.t(), map()) :: identity_result()
  def update_upstream_identity(%UpstreamIdentity{} = identity, attrs) when is_map(attrs) do
    update_identity(identity, attrs, plan_metadata: :ignore)
  end

  @spec upsert_upstream_identity(map()) :: identity_result()
  def upsert_upstream_identity(attrs) when is_map(attrs) do
    attrs = atomize_attrs(attrs)
    account_id = Map.get(attrs, :chatgpt_account_id)

    case get_upstream_identity_by_chatgpt_account(account_id) do
      %UpstreamIdentity{} = identity -> update_upstream_identity(identity, attrs)
      nil -> create_upstream_identity(attrs)
    end
  end

  @spec activate_upstream_identity(identity_ref(), map()) :: identity_result()
  def activate_upstream_identity(identity_or_id, attrs \\ %{}) do
    activate_identity(identity_or_id, attrs, plan_metadata: :ignore)
  end

  @spec disable_upstream_identity(identity_ref()) :: identity_result()
  def disable_upstream_identity(identity_or_id) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        update_upstream_identity(identity, %{status: @disabled, disabled_at: now()})

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  defp create_identity(attrs, opts) do
    now = now()

    attrs
    |> atomize_attrs()
    |> maybe_drop_plan_metadata(opts)
    |> put_default(:status, @pending)
    |> put_default(:headers_profile_version, 1)
    |> put_default(:metadata, %{})
    |> put_default(:created_at, now)
    |> put_default(:updated_at, now)
    |> then(&UpstreamIdentity.changeset(%UpstreamIdentity{}, &1))
    |> Repo.insert()
  end

  defp update_identity(%UpstreamIdentity{} = identity, attrs, opts) when is_map(attrs) do
    attrs =
      attrs
      |> atomize_attrs()
      |> maybe_drop_plan_metadata(opts)
      |> Map.put(:updated_at, now())

    identity
    |> UpstreamIdentity.changeset(attrs)
    |> Repo.update()
  end

  defp activate_identity(identity_or_id, attrs, opts) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        timestamp = now()
        attrs = atomize_attrs(attrs)

        update_identity(
          identity,
          attrs
          |> Map.merge(%{
            status: @active,
            auth_verified_at: Map.get(attrs, :auth_verified_at, timestamp),
            auth_fresh_at: Map.get(attrs, :auth_fresh_at, timestamp),
            disabled_at: nil
          }),
          opts
        )

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  defp get_upstream_identity_by_chatgpt_account(chatgpt_account_id)
       when is_binary(chatgpt_account_id) do
    Repo.get_by(UpstreamIdentity, chatgpt_account_id: String.trim(chatgpt_account_id))
  end

  defp get_upstream_identity_by_chatgpt_account(_chatgpt_account_id), do: nil

  defp maybe_drop_plan_metadata(attrs, plan_metadata: :allow), do: attrs

  defp maybe_drop_plan_metadata(attrs, plan_metadata: :ignore) do
    Map.drop(attrs, [:plan_family, :plan_label])
  end

  defp normalize_identity(%UpstreamIdentity{id: id}), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(id) when is_binary(id), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(_id), do: nil

  defp atomize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp put_default(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      _value -> map
    end
  end

  defp lifecycle_error(code, message), do: %{code: code, message: message}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
