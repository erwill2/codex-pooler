defmodule CodexPooler.Gateway.Persistence.RoutingCircuitStateTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.CircuitState
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings

  setup do
    old_config = Application.get_env(:codex_pooler, OperationalSettings, [])

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      old_config
      |> Keyword.delete(:settings)
      |> Keyword.put(:use_instance_settings?, true)
    )

    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()
    update_circuit_settings(%{"circuit_open_seconds" => 60, "circuit_half_open_probe_limit" => 1})

    on_exit(fn ->
      Application.put_env(:codex_pooler, OperationalSettings, old_config)
      Repo.delete_all(Settings)
      InstanceSettings.reset_cache_for_test()
    end)
  end

  test "half-open circuits reject new probes while a fresh probe is in flight" do
    {auth, model, assignment} = routing_fixture()
    half_open_circuit!(auth, model, assignment, updated_at: now(), probe_count: 1)

    refute CircuitState.eligible?(auth, model, assignment, "proxy_websocket")

    assert {:error, :routing_circuit_probe_in_flight} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")
  end

  test "half-open circuits recover stale in-flight probes" do
    {auth, model, assignment} = routing_fixture()
    stale_updated_at = DateTime.add(now(), -61, :second)

    state =
      half_open_circuit!(auth, model, assignment, updated_at: stale_updated_at, probe_count: 1)

    assert CircuitState.eligible?(auth, model, assignment, "proxy_websocket")

    assert {:ok, %RoutingCircuitState{} = updated} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    assert updated.id == state.id
    assert updated.metadata["probe_in_flight_count"] == 1
    assert DateTime.compare(updated.updated_at, state.updated_at) == :gt
  end

  test "failure threshold updates affect the next failure without resetting persisted counts" do
    {auth, model, assignment} = routing_fixture()

    assert {:ok, %RoutingCircuitState{} = first} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :first_failure
             )

    assert first.status == "closed"
    assert first.failure_count == 1

    update_circuit_settings(%{"circuit_failure_threshold" => 2})

    assert {:ok, %RoutingCircuitState{} = opened} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :second_failure
             )

    assert opened.id == first.id
    assert opened.status == "open"
    assert opened.failure_count == 2
    assert %DateTime{} = opened.next_probe_at
  end

  test "open-window updates change half-open probe decisions without resetting circuit rows" do
    {auth, model, assignment} = routing_fixture()
    prior_updated_at = DateTime.add(now(), -30, :second)

    state =
      half_open_circuit!(auth, model, assignment, updated_at: prior_updated_at, probe_count: 1)

    refute CircuitState.eligible?(auth, model, assignment, "proxy_websocket")

    assert {:error, :routing_circuit_probe_in_flight} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    update_circuit_settings(%{"circuit_open_seconds" => 10})

    assert CircuitState.eligible?(auth, model, assignment, "proxy_websocket")

    assert {:ok, %RoutingCircuitState{} = resumed} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    assert resumed.id == state.id
    assert resumed.metadata["probe_in_flight_count"] == 1
    assert DateTime.compare(resumed.updated_at, state.updated_at) == :gt
  end

  defp routing_fixture do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    model = model_fixture(pool)

    {%{pool: pool, api_key: api_key}, model, assignment}
  end

  defp half_open_circuit!(auth, model, assignment, attrs) do
    now = now()
    updated_at = Keyword.fetch!(attrs, :updated_at)
    probe_count = Keyword.fetch!(attrs, :probe_count)

    %RoutingCircuitState{
      pool_id: auth.pool.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      model_identifier: model.exposed_model_id,
      route_class: "proxy_websocket",
      status: "half_open",
      reason_code: "test_probe",
      failure_count: 3,
      success_count: 0,
      opened_at: DateTime.add(now, -120, :second),
      half_opened_at: updated_at,
      metadata: %{"probe_in_flight_count" => probe_count},
      created_at: DateTime.add(now, -120, :second),
      updated_at: updated_at
    }
    |> Repo.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp update_circuit_settings(attrs) do
    instance_settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update(instance_settings, %{"gateway" => attrs})
  end
end
