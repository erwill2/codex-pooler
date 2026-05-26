defmodule CodexPooler.Gateway.Routing.BridgeRingTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeAffinity, BridgeDemotion}
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  describe "plan_route/5 leaf ordering" do
    test "bridge_ring keeps rendezvous ordering stable for the same seed and candidate set" do
      setup = routing_setup(3)
      seed = "bridge-ring-stable-seed"

      expected_ids = rendezvous_order_ids(setup.candidates, seed)

      first_plan = plan_for(setup, "bridge_ring", seed)
      second_plan = plan_for(setup, "bridge_ring", seed)

      assert candidate_ids(first_plan.candidates) == expected_ids
      assert candidate_ids(second_plan.candidates) == expected_ids
      assert first_plan.selected_assignment_id == hd(expected_ids)
      assert second_plan.selected_assignment_id == hd(expected_ids)
    end

    test "deterministic_rotation rotates the current candidate list by seed" do
      setup = routing_setup(4)
      seed = "rotation-seed"
      base_ids = candidate_ids(setup.candidates)

      plan = plan_for(setup, "deterministic_rotation", seed)

      assert candidate_ids(plan.candidates) == rotated_ids(base_ids, seed)
    end

    test "deterministic_rotation is deterministic and not live round robin across calls" do
      setup = routing_setup(4)
      seed = "rotation-repeat-seed"

      first_plan = plan_for(setup, "deterministic_rotation", seed)
      second_plan = plan_for(setup, "deterministic_rotation", seed)

      assert candidate_ids(first_plan.candidates) == candidate_ids(second_plan.candidates)
      assert first_plan.selected_assignment_id == second_plan.selected_assignment_id
    end
  end

  describe "plan_route/5 deterministic distribution" do
    test "bridge_ring distributes first selection across fixed request seeds" do
      setup = routing_setup(3)

      assignment_ids = candidate_ids(setup.candidates)

      seeds =
        setup.assignments
        |> Enum.flat_map(fn assignment ->
          seeds_preferring_assignment(assignment_ids, assignment.id, 4)
        end)

      selected_ids =
        Enum.map(seeds, fn seed ->
          expected_ids = rendezvous_order_ids(setup.candidates, seed)
          plan = plan_for(setup, "bridge_ring", seed)

          assert candidate_ids(plan.candidates) == expected_ids
          assert plan.selected_assignment_id == hd(expected_ids)

          plan.selected_assignment_id
        end)

      expected_selected_ids = Enum.flat_map(setup.assignments, &List.duplicate(&1.id, 4))

      assert length(seeds) == 12
      assert selected_ids == expected_selected_ids

      selection_counts = Enum.frequencies(selected_ids)

      assert Enum.map(setup.assignments, &Map.fetch!(selection_counts, &1.id)) == [4, 4, 4]
    end

    test "deterministic_rotation distributes first selection across fixed request seeds" do
      setup = routing_setup(4)
      base_ids = candidate_ids(setup.candidates)

      seeds =
        0..3
        |> Enum.map(fn rotation_index ->
          seed_rotating_to_index(rotation_index, length(base_ids))
        end)

      selected_ids =
        Enum.map(seeds, fn seed ->
          expected_ids = rotated_ids(base_ids, seed)
          plan = plan_for(setup, "deterministic_rotation", seed)

          assert candidate_ids(plan.candidates) == expected_ids
          assert plan.selected_assignment_id == hd(expected_ids)

          plan.selected_assignment_id
        end)

      assert selected_ids == base_ids
    end

    test "least_recent_success uses assignment-global succeeded attempt recency and ignores failures" do
      setup = routing_setup(4)
      [first, second, third, fourth] = setup.assignments
      base_time = ~U[2026-05-09 10:00:00.000000Z]
      seed = seed_preferring_assignment([first.id, fourth.id], first.id)

      older_request =
        request_fixture(setup.auth, %{model_id: setup.model.id, correlation_id: "older"})

      newer_request =
        request_fixture(setup.auth, %{model_id: setup.model.id, correlation_id: "newer"})

      failed_request =
        request_fixture(setup.auth, %{model_id: setup.model.id, correlation_id: "failed"})

      attempt_fixture(older_request, second, %{
        attempt_number: 1,
        completed_at: DateTime.add(base_time, 10, :second)
      })

      attempt_fixture(newer_request, third, %{
        attempt_number: 1,
        completed_at: DateTime.add(base_time, 50, :second)
      })

      attempt_fixture(failed_request, second, %{
        attempt_number: 1,
        status: "failed",
        completed_at: DateTime.add(base_time, 90, :second)
      })

      attempt_fixture(failed_request, fourth, %{
        attempt_number: 2,
        status: "failed",
        completed_at: DateTime.add(base_time, 120, :second)
      })

      plan = plan_for(setup, "least_recent_success", seed)

      assert candidate_ids(plan.candidates) == [first.id, fourth.id, second.id, third.id]
      assert plan.selected_assignment_id == first.id
    end

    test "least_recent_success breaks equal recency ties with rendezvous order" do
      setup = routing_setup(3)
      [first, second, third] = setup.assignments
      shared_time = ~U[2026-05-09 11:00:00.000000Z]
      seed = seed_preferring_assignment([first.id, second.id], first.id)

      shared_request =
        request_fixture(setup.auth, %{model_id: setup.model.id, correlation_id: "tie"})

      attempt_fixture(shared_request, first, %{attempt_number: 1, completed_at: shared_time})
      attempt_fixture(shared_request, second, %{attempt_number: 2, completed_at: shared_time})

      plan = plan_for(setup, "least_recent_success", seed)

      assert candidate_ids(plan.candidates) == [third.id, first.id, second.id]
      assert plan.selected_assignment_id == third.id
    end

    test "least_recent_success puts no-success candidates before older successes and ties them by rendezvous" do
      setup = routing_setup(4)
      [first, second, third, fourth] = setup.assignments
      shared_time = ~U[2026-05-09 12:00:00.000000Z]
      seed = seed_preferring_assignment([first.id, third.id], third.id)

      shared_request =
        request_fixture(setup.auth, %{model_id: setup.model.id, correlation_id: "no-success-tie"})

      attempt_fixture(shared_request, second, %{attempt_number: 1, completed_at: shared_time})
      attempt_fixture(shared_request, fourth, %{attempt_number: 2, completed_at: shared_time})

      plan = plan_for(setup, "least_recent_success", seed)

      no_success_candidates = [
        {first, Enum.at(setup.identities, 0)},
        {third, Enum.at(setup.identities, 2)}
      ]

      equal_success_candidates = [
        {second, Enum.at(setup.identities, 1)},
        {fourth, Enum.at(setup.identities, 3)}
      ]

      expected_ids =
        rendezvous_order_ids(no_success_candidates, seed) ++
          rendezvous_order_ids(equal_success_candidates, seed)

      assert candidate_ids(plan.candidates) == expected_ids
      assert plan.selected_assignment_id == hd(expected_ids)
    end
  end

  describe "plan_route/5 quota-first edge cases" do
    test "quota_first orders by quota headroom before rendezvous tie-breaking" do
      setup = routing_setup(3)
      [low_headroom, high_headroom, middle_headroom] = setup.assignments
      [_low_identity, high_identity, _middle_identity] = setup.identities
      seed = seed_preferring_assignment([low_headroom.id, high_headroom.id], low_headroom.id)

      prime_account_quota!(setup, low_headroom, Decimal.new("90"))
      prime_account_quota!(setup, high_headroom, Decimal.new("10"))
      prime_account_quota!(setup, middle_headroom, Decimal.new("50"))
      quota_first_plan = plan_for(setup, "quota_first", seed)

      assert quota_first_plan.selected_assignment_id == high_headroom.id
      assert hd(quota_first_plan.candidates) == {high_headroom, high_identity}
    end

    test "quota_first breaks equal headroom ties by rendezvous order" do
      setup = routing_setup(2)
      [first, second] = setup.assignments
      seed = seed_preferring_assignment([first.id, second.id], second.id)

      prime_account_quota!(setup, first, Decimal.new("40"))
      prime_account_quota!(setup, second, Decimal.new("40"))

      quota_first_plan = plan_for(setup, "quota_first", seed)
      expected_ids = rendezvous_order_ids(setup.candidates, seed)

      assert candidate_ids(quota_first_plan.candidates) == expected_ids
      assert quota_first_plan.selected_assignment_id == hd(expected_ids)
    end

    test "quota_first gives missing usable quota a zero headroom score" do
      setup = routing_setup(3)
      [unknown_quota, high_headroom, low_headroom] = setup.assignments
      seed = seed_preferring_assignment([unknown_quota.id, high_headroom.id], unknown_quota.id)

      prime_account_quota!(setup, high_headroom, Decimal.new("20"))
      prime_account_quota!(setup, low_headroom, Decimal.new("95"))

      quota_first_plan = plan_for(setup, "quota_first", seed)

      assert candidate_ids(quota_first_plan.candidates) == [
               high_headroom.id,
               low_headroom.id,
               unknown_quota.id
             ]

      assert quota_first_plan.selected_assignment_id == high_headroom.id
    end

    test "quota_first scores model-scoped quota with only in-scope usable windows" do
      setup = routing_setup(2)
      [requested_model_headroom, fallback_headroom] = setup.assignments

      seed =
        seed_preferring_assignment(
          [requested_model_headroom.id, fallback_headroom.id],
          fallback_headroom.id
        )

      prime_account_quota!(setup, requested_model_headroom, Decimal.new("5"))
      prime_model_quota!(setup, requested_model_headroom, Decimal.new("30"))

      prime_model_quota!(setup, requested_model_headroom, Decimal.new("99"),
        model: "other-model",
        upstream_model: "other-upstream-model"
      )

      prime_account_quota!(setup, fallback_headroom, Decimal.new("5"))
      prime_model_quota!(setup, fallback_headroom, Decimal.new("40"))

      quota_first_plan = plan_for(setup, "quota_first", seed)

      assert candidate_ids(quota_first_plan.candidates) == [
               requested_model_headroom.id,
               fallback_headroom.id
             ]

      assert quota_first_plan.selected_assignment_id == requested_model_headroom.id
    end
  end

  describe "plan_route/5 affinity/demotion recovery" do
    test "affinity cannot resurrect a filtered assignment that is absent from eligible candidates" do
      setup = routing_setup(3)
      seed = "filtered-affinity-seed"
      filtered = active_upstream_assignment_fixture(setup.pool)

      insert_affinity!(setup, filtered.assignment, filtered.identity, seed)

      plan = plan_for(setup, "bridge_ring", seed)

      assert plan.affinity.status == "hit"
      assert filtered.assignment.id not in candidate_ids(plan.candidates)
      assert candidate_ids(plan.candidates) == rendezvous_order_ids(setup.candidates, seed)
    end

    test "affinity promotes an eligible sticky hit after strategy ordering" do
      setup = routing_setup(3)
      seed = "eligible-affinity-seed"
      base_ids = rendezvous_order_ids(setup.candidates, seed)
      sticky_id = List.last(base_ids)
      {sticky_assignment, sticky_identity} = candidate_by_id!(setup.candidates, sticky_id)

      insert_affinity!(setup, sticky_assignment, sticky_identity, seed)

      plan = plan_for(setup, "bridge_ring", seed)

      assert plan.affinity.status == "hit"

      assert candidate_ids(plan.candidates) == [
               sticky_id | Enum.reject(base_ids, &(&1 == sticky_id))
             ]

      assert plan.selected_assignment_id == sticky_id
    end

    test "active demotion pushes an affinity hit behind non-demoted alternatives" do
      setup = routing_setup(3)
      seed = "affinity-then-demotion-seed"
      base_ids = rendezvous_order_ids(setup.candidates, seed)
      sticky_id = List.last(base_ids)
      {sticky_assignment, sticky_identity} = candidate_by_id!(setup.candidates, sticky_id)

      insert_affinity!(setup, sticky_assignment, sticky_identity, seed)
      insert_demotion!(setup, sticky_assignment, sticky_identity, "upstream_5xx")

      plan = plan_for(setup, "bridge_ring", seed)

      assert plan.affinity.status == "hit"
      assert Map.has_key?(plan.demotions, sticky_id)

      assert candidate_ids(plan.candidates) ==
               Enum.reject(base_ids, &(&1 == sticky_id)) ++ [sticky_id]

      assert plan.selected_assignment_id == hd(Enum.reject(base_ids, &(&1 == sticky_id)))
    end

    test "expired demotion is ignored when ordering candidates" do
      setup = routing_setup(3)
      seed = "expired-demotion-seed"
      base_ids = rendezvous_order_ids(setup.candidates, seed)
      selected_id = hd(base_ids)
      {selected_assignment, selected_identity} = candidate_by_id!(setup.candidates, selected_id)

      insert_demotion!(setup, selected_assignment, selected_identity, "upstream_5xx",
        demoted_until: ~U[2026-05-09 10:00:00.000000Z],
        now: ~U[2026-05-09 09:59:00.000000Z]
      )

      plan = plan_for(setup, "bridge_ring", seed)

      assert plan.demotions == %{}
      assert candidate_ids(plan.candidates) == base_ids
      assert plan.selected_assignment_id == selected_id
    end

    test "record_success resolves active demotions for the successful assignment" do
      setup = routing_setup(3)
      seed = "success-resolves-demotion-seed"
      base_ids = rendezvous_order_ids(setup.candidates, seed)
      demoted_id = hd(base_ids)
      {demoted_assignment, demoted_identity} = candidate_by_id!(setup.candidates, demoted_id)

      insert_demotion!(setup, demoted_assignment, demoted_identity, "upstream_5xx",
        demoted_until: nil,
        now: ~U[2026-05-09 10:00:00.000000Z]
      )

      demoted_plan = plan_for(setup, "bridge_ring", seed)

      assert Map.has_key?(demoted_plan.demotions, demoted_id)
      assert candidate_ids(demoted_plan.candidates) == tl(base_ids) ++ [demoted_id]

      assert :ok = BridgeRing.record_success(demoted_plan, demoted_assignment, demoted_identity)

      assert [] = active_demotions(setup, demoted_assignment)

      resolved_demotions = all_demotions(setup, demoted_assignment)
      assert [%BridgeDemotion{} = resolved_demotion] = resolved_demotions
      assert resolved_demotion.status == "resolved"

      recovered_plan = plan_for(setup, "bridge_ring", seed)

      assert recovered_plan.demotions == %{}
      assert candidate_ids(recovered_plan.candidates) == base_ids
      assert recovered_plan.selected_assignment_id == demoted_id
    end

    test "bridge_ring_size truncates candidates after strategy ordering affinity and demotion" do
      setup = routing_setup(4)
      seed = "ring-size-truncation-seed"
      base_ids = rendezvous_order_ids(setup.candidates, seed)
      sticky_id = List.last(base_ids)
      demoted_id = Enum.at(base_ids, 1)
      {sticky_assignment, sticky_identity} = candidate_by_id!(setup.candidates, sticky_id)
      {demoted_assignment, demoted_identity} = candidate_by_id!(setup.candidates, demoted_id)

      insert_affinity!(setup, sticky_assignment, sticky_identity, seed)
      insert_demotion!(setup, demoted_assignment, demoted_identity, "upstream_5xx")

      plan = plan_for(setup, "bridge_ring", seed, ring_size: 2)

      affinity_order = [sticky_id | Enum.reject(base_ids, &(&1 == sticky_id))]
      expected_ids = Enum.reject(affinity_order, &(&1 == demoted_id)) ++ [demoted_id]

      assert plan.bridge_ring_size == 2
      assert candidate_ids(plan.candidates) == Enum.take(expected_ids, 2)
      assert length(plan.candidates) == 2
      assert plan.selected_assignment_id == hd(expected_ids)
    end
  end

  describe "record_success/3 concurrency" do
    test "concurrent first successes for the same affinity key leave one active affinity" do
      setup = routing_setup(2)
      seed = "concurrent-affinity-key"
      plan = plan_for(setup, "bridge_ring", seed)
      {assignment, identity} = hd(plan.candidates)
      concurrency = 8

      assert plan.affinity.status == "miss"

      assert List.duplicate(:ok, concurrency) ==
               run_concurrently(concurrency, fn ->
                 BridgeRing.record_success(plan, assignment, identity)
               end)

      active_affinities = active_affinities(setup, seed)
      assert [%BridgeAffinity{} = affinity] = active_affinities
      assert affinity.pool_upstream_assignment_id == assignment.id
      assert affinity.upstream_identity_id == identity.id
      assert affinity.metadata == %{"source" => "gateway_success"}
      refute is_nil(affinity.last_hit_at)
      assert DateTime.compare(affinity.created_at, affinity.updated_at) in [:lt, :eq]
    end
  end

  describe "record_failure/5 concurrency" do
    test "concurrent first failures for the same assignment leave one active demotion" do
      setup = routing_setup(2)
      seed = "concurrent-demotion-key"
      plan = plan_for(setup, "bridge_ring", seed)
      {assignment, identity} = hd(plan.candidates)
      concurrency = 8

      assert List.duplicate("upstream_5xx", concurrency) ==
               run_concurrently(concurrency, fn ->
                 BridgeRing.record_failure(plan, assignment, identity, "upstream_5xx")
               end)

      active_demotions = active_demotions(setup, assignment)
      assert [%BridgeDemotion{} = demotion] = active_demotions
      assert demotion.pool_upstream_assignment_id == assignment.id
      assert demotion.upstream_identity_id == identity.id
      assert demotion.reason_code == "upstream_5xx"
      assert demotion.metadata == %{"source" => "gateway_failure"}
      assert demotion.attempt_count == concurrency
      assert DateTime.compare(demotion.created_at, demotion.updated_at) in [:lt, :eq]
      assert DateTime.compare(demotion.updated_at, demotion.demoted_until) == :lt
    end
  end

  defp routing_setup(candidate_count) do
    pool =
      pool_fixture(%{
        slug:
          "bridge-pool-#{System.unique_integer([:positive, :monotonic])}-#{System.os_time(:nanosecond)}"
      })

    auth = active_api_key_fixture(pool)

    assignments_with_identities =
      Enum.map(1..candidate_count, fn index ->
        unique =
          "#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"

        active_upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct_bridge_#{index}_#{unique}",
          assignment_label: "Bridge assignment #{index}",
          account_label: "Bridge identity #{index}",
          metadata: %{
            "quota_remaining_pct" => Integer.to_string(100 - index * 10),
            "quota_bucket" => "bucket-#{index}"
          }
        })
      end)

    assignment_ids = Enum.map(assignments_with_identities, & &1.assignment.id)

    model =
      model_fixture(pool, %{
        metadata: %{"source_assignment_ids" => assignment_ids},
        source_assignment_count: candidate_count
      })

    %{
      pool: pool,
      auth: %{pool: pool, api_key: auth.api_key},
      model: model,
      assignments: Enum.map(assignments_with_identities, & &1.assignment),
      identities: Enum.map(assignments_with_identities, & &1.identity),
      candidates: Enum.map(assignments_with_identities, &{&1.assignment, &1.identity})
    }
  end

  defp plan_for(setup, strategy, seed, opts \\ []) do
    ring_size = Keyword.get(opts, :ring_size, length(setup.candidates))
    update_routing_settings!(setup.pool, strategy, ring_size)

    request =
      request_fixture(setup.auth, %{
        model_id: setup.model.id,
        requested_model: setup.model.exposed_model_id,
        correlation_id: "#{seed}-#{System.unique_integer([:positive])}"
      })

    BridgeRing.plan_route(
      setup.auth,
      setup.model,
      setup.candidates,
      RoutePlanInput.from_reserved(%{request: request}),
      RequestOptions.build(%{request_id: seed}, "/backend-api/codex/responses", %{})
    )
  end

  defp update_routing_settings!(pool, strategy, ring_size) do
    pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(%{
      routing_strategy: strategy,
      bridge_ring_size: ring_size,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp candidate_ids(candidates),
    do: Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)

  defp candidate_by_id!(candidates, assignment_id) do
    Enum.find(candidates, fn {assignment, _identity} -> assignment.id == assignment_id end) ||
      raise "missing candidate #{assignment_id}"
  end

  defp insert_affinity!(setup, assignment, identity, request_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %BridgeAffinity{
      pool_id: setup.pool.id,
      api_key_id: setup.auth.api_key.id,
      model_identifier: setup.model.exposed_model_id,
      affinity_kind: "request_correlation",
      affinity_key_hash: affinity_hash(setup, "request_correlation", request_id),
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      status: "active",
      last_hit_at: now,
      metadata: %{"source" => "test_affinity"},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp insert_demotion!(setup, assignment, identity, reason_code, opts \\ []) do
    now =
      opts
      |> Keyword.get_lazy(:now, fn -> DateTime.utc_now() end)
      |> DateTime.truncate(:microsecond)

    demoted_until =
      case Keyword.get_lazy(opts, :demoted_until, fn -> DateTime.add(now, 60, :second) end) do
        nil -> nil
        value -> DateTime.truncate(value, :microsecond)
      end

    %BridgeDemotion{
      pool_id: setup.pool.id,
      api_key_id: setup.auth.api_key.id,
      model_identifier: setup.model.exposed_model_id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      reason_code: reason_code,
      status: "active",
      demoted_until: demoted_until,
      attempt_count: 1,
      metadata: %{"source" => "test_demotion"},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp prime_account_quota!(setup, assignment, used_percent) do
    prime_quota_window!(setup, assignment, %{
      quota_key: "account",
      window_kind: "primary",
      window_minutes: 300,
      quota_scope: "account",
      quota_family: "account",
      used_percent: used_percent
    })
  end

  defp prime_model_quota!(setup, assignment, used_percent, opts \\ []) do
    model = Keyword.get(opts, :model, setup.model.exposed_model_id)
    upstream_model = Keyword.get(opts, :upstream_model, setup.model.upstream_model_id)

    prime_quota_window!(setup, assignment, %{
      quota_key: "codex_model",
      window_kind: "primary",
      window_minutes: 300,
      quota_scope: "model",
      quota_family: "codex_model",
      model: model,
      upstream_model: upstream_model,
      used_percent: used_percent
    })
  end

  defp prime_quota_window!(setup, assignment, attrs) do
    {_assignment, identity} = candidate_by_id!(setup.candidates, assignment.id)

    reset_at =
      DateTime.utc_now()
      |> DateTime.add(900, :second)
      |> DateTime.truncate(:second)

    attrs =
      Map.merge(
        %{
          reset_at: reset_at,
          source: "codex_response_headers",
          source_precision: "observed",
          freshness_state: "fresh"
        },
        attrs
      )

    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [attrs])
  end

  defp affinity_hash(setup, kind, key_value) do
    [setup.pool.id, setup.auth.api_key.id, setup.model.exposed_model_id, kind, key_value]
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp active_affinities(setup, seed) do
    Repo.all(
      from affinity in BridgeAffinity,
        where:
          affinity.pool_id == ^setup.pool.id and affinity.api_key_id == ^setup.auth.api_key.id and
            affinity.model_identifier == ^setup.model.exposed_model_id and
            affinity.affinity_kind == "request_correlation" and
            affinity.affinity_key_hash == ^affinity_hash(setup, "request_correlation", seed) and
            affinity.status == "active"
    )
  end

  defp active_demotions(setup, assignment) do
    Repo.all(
      from demotion in BridgeDemotion,
        where:
          demotion.pool_id == ^setup.pool.id and demotion.api_key_id == ^setup.auth.api_key.id and
            demotion.model_identifier == ^setup.model.exposed_model_id and
            demotion.pool_upstream_assignment_id == ^assignment.id and
            demotion.status == "active"
    )
  end

  defp all_demotions(setup, assignment) do
    Repo.all(
      from demotion in BridgeDemotion,
        where:
          demotion.pool_id == ^setup.pool.id and demotion.api_key_id == ^setup.auth.api_key.id and
            demotion.model_identifier == ^setup.model.exposed_model_id and
            demotion.pool_upstream_assignment_id == ^assignment.id,
        order_by: [asc: demotion.created_at]
    )
  end

  defp run_concurrently(count, callback) do
    parent = self()
    barrier = make_ref()

    tasks =
      Enum.map(1..count, fn _index ->
        Task.async(fn ->
          send(parent, {:bridge_ring_concurrency_ready, barrier, self()})

          receive do
            {:bridge_ring_concurrency_go, ^barrier} -> callback.()
          after
            5_000 -> raise "timed out waiting for concurrency release"
          end
        end)
      end)

    ready_pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:bridge_ring_concurrency_ready, ^barrier, task_pid}
        task_pid
      end)

    assert Enum.sort(ready_pids) == Enum.sort(Enum.map(tasks, & &1.pid))

    Enum.each(tasks, fn task ->
      send(task.pid, {:bridge_ring_concurrency_go, barrier})
    end)

    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp rotated_ids(candidate_ids, _seed) when length(candidate_ids) <= 1, do: candidate_ids

  defp rotated_ids(candidate_ids, seed) do
    {head, tail} = Enum.split(candidate_ids, :erlang.phash2(seed, length(candidate_ids)))
    tail ++ head
  end

  defp rendezvous_order_ids(candidates, seed) do
    candidates
    |> Enum.sort_by(fn {assignment, _identity} -> -rendezvous_score(seed, assignment.id) end)
    |> candidate_ids()
  end

  defp seed_rotating_to_index(rotation_index, candidate_count) do
    Enum.find(1..500, fn index ->
      :erlang.phash2("rotation-distribution-#{index}", candidate_count) == rotation_index
    end)
    |> then(&"rotation-distribution-#{&1}")
  end

  defp seeds_preferring_assignment(assignment_ids, desired_assignment_id, count) do
    1..2_000
    |> Enum.reduce_while([], fn index, seeds ->
      seed = "bridge-ring-distribution-seed-#{index}"

      selected_assignment_id = Enum.max_by(assignment_ids, &rendezvous_score(seed, &1))

      seeds = if selected_assignment_id == desired_assignment_id, do: [seed | seeds], else: seeds

      if length(seeds) == count, do: {:halt, Enum.reverse(seeds)}, else: {:cont, seeds}
    end)
  end

  defp seed_preferring_assignment(assignment_ids, desired_assignment_id) do
    Enum.find(1..500, fn index ->
      seed = "bridge-ring-seed-#{index}"

      assignment_ids
      |> Enum.max_by(&rendezvous_score(seed, &1))
      |> Kernel.==(desired_assignment_id)
    end)
    |> then(&"bridge-ring-seed-#{&1}")
  end

  defp rendezvous_score(seed, assignment_id) do
    :crypto.hash(:sha256, [to_string(seed), ?:, assignment_id])
    |> :binary.decode_unsigned()
  end
end
