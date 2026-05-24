defmodule CodexPoolerWeb.Admin.PoolEventSubscriptions do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, update: 3]

  alias CodexPooler.Events
  alias Phoenix.LiveView.Socket
  alias Phoenix.PubSub

  @type pool_id_set :: map()

  @spec pool_id_set([%{id: String.t()}]) :: pool_id_set()
  def pool_id_set(pools) when is_list(pools) do
    pools
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  @spec reconcile(map(), pool_id_set()) :: {map(), pool_id_set()}
  def reconcile(%Socket{} = socket, target_pool_ids) do
    if Phoenix.LiveView.connected?(socket) do
      subscribed_pool_ids = subscribed_pool_ids(socket)
      stale_pool_ids = difference(subscribed_pool_ids, target_pool_ids)
      new_pool_ids = difference(target_pool_ids, subscribed_pool_ids)

      Enum.each(stale_pool_ids, fn pool_id ->
        :ok = PubSub.unsubscribe(CodexPooler.PubSub, Events.pubsub_topic(pool_id))
      end)

      Enum.each(new_pool_ids, fn pool_id ->
        :ok = Events.subscribe_pool(pool_id)
      end)

      {assign(socket, :subscribed_pool_ids, target_pool_ids), stale_pool_ids}
    else
      {socket, MapSet.new()}
    end
  end

  @spec subscribe_missing(map(), pool_id_set()) :: map()
  def subscribe_missing(%Socket{} = socket, target_pool_ids) do
    if Phoenix.LiveView.connected?(socket) do
      target_pool_ids
      |> difference(subscribed_pool_ids(socket))
      |> Enum.reduce(socket, fn pool_id, socket ->
        :ok = Events.subscribe_pool(pool_id)
        update(socket, :subscribed_pool_ids, &MapSet.put(&1, pool_id))
      end)
    else
      socket
    end
  end

  @spec maybe_cancel_timer_on_stale(map(), pool_id_set(), (map() -> map())) :: map()
  def maybe_cancel_timer_on_stale(%Socket{} = socket, stale_pool_ids, cancel_timer) do
    if Enum.empty?(stale_pool_ids) do
      socket
    else
      cancel_timer.(socket)
    end
  end

  @spec subscribed_pool_ids(map()) :: pool_id_set()
  def subscribed_pool_ids(%Socket{} = socket) do
    case socket.assigns[:subscribed_pool_ids] do
      %MapSet{} = pool_ids -> pool_ids
      _other -> MapSet.new()
    end
  end

  defp difference(pool_ids, excluded_pool_ids) do
    pool_ids
    |> Enum.reject(&MapSet.member?(excluded_pool_ids, &1))
    |> MapSet.new()
  end
end
