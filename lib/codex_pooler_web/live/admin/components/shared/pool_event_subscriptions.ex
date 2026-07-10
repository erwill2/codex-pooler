defmodule CodexPoolerWeb.Admin.PoolEventSubscriptions do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, update: 3]

  alias CodexPooler.Events
  alias Phoenix.LiveView.Socket

  @type pool_id_set :: MapSet.t(String.t())
  @type event_topics :: :all | MapSet.t(Events.topic())
  @type reconcile_result :: {Socket.t(), pool_id_set()} | {:error, :invalid_topics}

  @spec pool_id_set([%{id: String.t()}]) :: pool_id_set()
  def pool_id_set(pools) when is_list(pools) do
    pools
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  @spec reconcile(Socket.t(), pool_id_set(), :all | Events.topics()) :: reconcile_result()
  def reconcile(%Socket{} = socket, target_pool_ids, topics \\ :all) do
    with {:ok, target_topics} <- normalize_event_topics(topics) do
      reconcile_valid_topics(socket, target_pool_ids, target_topics)
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

  @spec subscribed_event_topics(Socket.t()) :: event_topics()
  def subscribed_event_topics(%Socket{} = socket) do
    case socket.assigns[:subscribed_pool_event_topics] do
      %MapSet{} = topics -> topics
      :all -> :all
      _other -> :all
    end
  end

  defp reconcile_valid_topics(socket, target_pool_ids, target_topics) do
    if Phoenix.LiveView.connected?(socket) do
      subscribed_pool_ids = subscribed_pool_ids(socket)
      subscribed_topics = subscribed_event_topics(socket)
      stale_pool_ids = difference(subscribed_pool_ids, target_pool_ids)

      unsubscribe_stale_channels(
        subscribed_pool_ids,
        subscribed_topics,
        target_pool_ids,
        target_topics
      )

      subscribe_new_channels(
        subscribed_pool_ids,
        subscribed_topics,
        target_pool_ids,
        target_topics
      )

      socket =
        socket
        |> assign(:subscribed_pool_ids, target_pool_ids)
        |> assign(:subscribed_pool_event_topics, target_topics)

      {socket, stale_pool_ids}
    else
      {socket, MapSet.new()}
    end
  end

  defp normalize_event_topics(:all), do: {:ok, :all}

  defp normalize_event_topics(topics) do
    case Events.validate_topics(topics) do
      {:ok, topics} -> {:ok, MapSet.new(topics)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unsubscribe_stale_channels(old_pool_ids, old_topics, new_pool_ids, new_topics) do
    old_pool_ids
    |> subscription_channels(old_topics)
    |> MapSet.difference(subscription_channels(new_pool_ids, new_topics))
    |> Enum.each(fn {pool_id, topics} -> :ok = unsubscribe(pool_id, topics) end)
  end

  defp subscribe_new_channels(old_pool_ids, old_topics, new_pool_ids, new_topics) do
    new_pool_ids
    |> subscription_channels(new_topics)
    |> MapSet.difference(subscription_channels(old_pool_ids, old_topics))
    |> Enum.each(fn {pool_id, topics} -> :ok = subscribe(pool_id, topics) end)
  end

  defp subscription_channels(pool_ids, topics) do
    for pool_id <- pool_ids,
        topic <- channel_topics(topics),
        into: MapSet.new(),
        do: {pool_id, topic}
  end

  defp subscribe(pool_id, :all), do: Events.subscribe_pool(pool_id)
  defp subscribe(pool_id, topic), do: Events.subscribe_pool(pool_id, topic)

  defp unsubscribe(pool_id, :all), do: Events.unsubscribe_pool(pool_id)
  defp unsubscribe(pool_id, topic), do: Events.unsubscribe_pool(pool_id, topic)

  defp channel_topics(:all), do: [:all]
  defp channel_topics(topics), do: topics

  defp difference(pool_ids, excluded_pool_ids) do
    pool_ids
    |> Enum.reject(&MapSet.member?(excluded_pool_ids, &1))
    |> MapSet.new()
  end
end
