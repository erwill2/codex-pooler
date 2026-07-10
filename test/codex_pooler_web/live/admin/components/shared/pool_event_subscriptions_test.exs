defmodule CodexPoolerWeb.Admin.PoolEventSubscriptionsTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Events
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias Phoenix.LiveView.Socket

  import CodexPooler.PoolerFixtures

  test "reconcile removes stale pool and topic channels exactly" do
    first_pool = pool_fixture()
    second_pool = pool_fixture()
    socket = connected_socket()

    assert {socket, stale_pool_ids} =
             PoolEventSubscriptions.reconcile(
               socket,
               MapSet.new([first_pool.id, second_pool.id]),
               ["pools", "upstreams"]
             )

    assert stale_pool_ids == MapSet.new()
    assert socket.assigns.subscribed_pool_event_topics == MapSet.new(["pools", "upstreams"])

    assert {socket, stale_pool_ids} =
             PoolEventSubscriptions.reconcile(socket, MapSet.new([second_pool.id]), ["pools"])

    assert stale_pool_ids == MapSet.new([first_pool.id])
    assert socket.assigns.subscribed_pool_ids == MapSet.new([second_pool.id])
    assert socket.assigns.subscribed_pool_event_topics == MapSet.new(["pools"])

    first_event = event(first_pool.id, ["pools"])
    second_upstreams_event = event(second_pool.id, ["upstreams"])
    second_pools_event = event(second_pool.id, ["pools"])

    assert :ok = publish(fn -> Events.broadcast_local_event(first_event) end)
    assert :ok = publish(fn -> Events.broadcast_local_event(second_upstreams_event) end)
    refute_receive {Events, ^first_event}
    refute_receive {Events, ^second_upstreams_event}

    assert :ok = publish(fn -> Events.broadcast_local_event(second_pools_event) end)
    assert_receive {Events, ^second_pools_event}
  end

  test "two-argument reconcile retains broad subscription state" do
    pool = pool_fixture()

    assert {socket, stale_pool_ids} =
             PoolEventSubscriptions.reconcile(connected_socket(), MapSet.new([pool.id]))

    assert stale_pool_ids == MapSet.new()
    assert socket.assigns.subscribed_pool_event_topics == :all

    event = event(pool.id, ["usage"])
    assert :ok = publish(fn -> Events.broadcast_local_event(event) end)
    assert_receive {Events, ^event}
  end

  test "reconcile rejects invalid topics without changing subscriptions" do
    pool = pool_fixture()
    socket = connected_socket()

    assert {:error, :invalid_topics} =
             PoolEventSubscriptions.reconcile(socket, MapSet.new([pool.id]), ["unknown"])

    event = event(pool.id, ["pools"])
    assert :ok = publish(fn -> Events.broadcast_local_event(event) end)
    refute_receive {Events, ^event}
  end

  defp connected_socket do
    %Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}, subscribed_pool_ids: MapSet.new()}
    }
  end

  defp publish(fun) do
    fun
    |> Task.async()
    |> Task.await(5_000)
  end

  defp event(pool_id, topics) do
    %Events.Event{
      version: 1,
      id: Ecto.UUID.generate(),
      pool_id: pool_id,
      topics: topics,
      reason: "test_event",
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      payload: %{}
    }
  end
end
