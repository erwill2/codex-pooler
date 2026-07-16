defmodule CodexPooler.Admin.StatsAuthorizationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.Stats
  alias CodexPooler.Upstreams.Assignments.PoolAssignments

  test "invalid and unauthorized scopes fail without returning data" do
    pool = pool_fixture(%{slug: "stats-invalid", name: "Stats Invalid"})
    scope = owner_scope()

    assert {:error, %{code: :invalid_window}} =
             Stats.build_dashboard(scope, %{window: "30d"})

    assert {:error, %{code: :pool_not_found}} =
             Stats.build_dashboard(scope, %{pool_id: Ecto.UUID.generate()})

    assert {:error, %{code: :unauthorized}} = Stats.build_dashboard(nil, %{pool_id: pool.id})
  end

  test "owners get all-pool reporting stats and owner filter candidates" do
    scope = owner_scope()
    pool_a = pool_fixture(%{slug: "stats-owner-a", name: "Stats Owner A"})
    pool_b = pool_fixture(%{slug: "stats-owner-b", name: "Stats Owner B"})
    pool_c = pool_fixture(%{slug: "stats-owner-c", name: "Stats Owner C"})

    stats_usage_fixture(pool_a, 10, "Owner A key")
    stats_usage_fixture(pool_b, 20, "Owner B key")
    stats_usage_fixture(pool_c, 30, "Owner C key")

    assert {:ok, dashboard} = Stats.build_dashboard(scope, %{window: "24h"})

    assert dashboard.selected_pool == nil
    assert dashboard.kpis.requests.value == 3
    assert dashboard.kpis.tokens.total_tokens == 60

    assert dashboard.filters.pool_options |> Enum.map(& &1.id) |> MapSet.new() ==
             MapSet.new([pool_a.id, pool_b.id, pool_c.id])

    assert dashboard.tables.top_api_keys |> Enum.map(& &1.display_name) |> MapSet.new() ==
             MapSet.new(["Owner A key", "Owner B key", "Owner C key"])
  end

  test "assigned admins get aggregate stats across assigned pools only" do
    %{user: owner} = bootstrap_owner_fixture()
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => "stats-admin@example.com"})
    pool_a = pool_fixture(%{slug: "stats-assigned-a", name: "Stats Assigned A"})
    pool_b = pool_fixture(%{slug: "stats-assigned-b", name: "Stats Assigned B"})
    pool_c = pool_fixture(%{slug: "stats-assigned-c", name: "Stats Assigned C"})

    operator_pool_assignment_fixture(admin, pool_a, created_by_user_id: owner.id)
    operator_pool_assignment_fixture(admin, pool_b, created_by_user_id: owner.id)

    stats_usage_fixture(pool_a, 10, "Assigned A key")
    stats_usage_fixture(pool_b, 20, "Assigned B key")
    stats_usage_fixture(pool_c, 30, "Hidden C key")

    admin_scope = Scope.for_user(admin)

    assert {:ok, dashboard} = Stats.build_dashboard(admin_scope, %{window: "24h"})

    assert dashboard.kpis.requests.value == 2
    assert dashboard.kpis.tokens.total_tokens == 30

    assert dashboard.filters.pool_options |> Enum.map(& &1.id) |> MapSet.new() ==
             MapSet.new([pool_a.id, pool_b.id])

    top_key_names = Enum.map(dashboard.tables.top_api_keys, & &1.display_name)

    assert "Assigned A key" in top_key_names
    assert "Assigned B key" in top_key_names
    refute "Hidden C key" in top_key_names

    assert {:ok, pool_a_dashboard} =
             Stats.build_dashboard(admin_scope, %{pool_id: pool_a.id, window: "24h"})

    assert pool_a_dashboard.selected_pool.id == pool_a.id
    assert pool_a_dashboard.kpis.tokens.total_tokens == 10

    assert {:ok, pool_b_dashboard} =
             Stats.build_dashboard(admin_scope, %{pool_id: pool_b.id, window: "24h"})

    assert pool_b_dashboard.selected_pool.id == pool_b.id
    assert pool_b_dashboard.kpis.tokens.total_tokens == 20

    assert {:error, %{code: :pool_not_found, message: hidden_message}} =
             Stats.build_dashboard(admin_scope, %{pool_id: pool_c.id, window: "24h"})

    assert {:error, %{code: :pool_not_found, message: random_message}} =
             Stats.build_dashboard(admin_scope, %{pool_id: Ecto.UUID.generate(), window: "24h"})

    assert hidden_message == random_message

    assert {:ok, owner_dashboard} = Stats.build_dashboard(owner_scope, %{window: "24h"})
    assert owner_dashboard.kpis.tokens.total_tokens == 60
  end

  test "assigned admins recalculate traffic shares for visible and selected pools" do
    fixtures = authorization_traffic_fixture()
    admin_scope = fixtures.admin_scope
    shared_identity_id = fixtures.shared_identity.id
    visible_identity_id = fixtures.visible_identity.id
    hidden_identity_id = fixtures.hidden_identity.id

    assert {:ok, all_pools_dashboard} =
             Stats.build_dashboard(admin_scope, %{window: "24h"})

    assert all_pools_dashboard.selected_pool == nil

    assert MapSet.new(Enum.map(all_pools_dashboard.filters.pool_options, & &1.id)) ==
             MapSet.new([fixtures.pools.visible_a.id, fixtures.pools.visible_b.id])

    assert [
             %{
               upstream_identity_id: ^shared_identity_id,
               assignment_count: 2,
               requests: 3,
               traffic_share_percent: 75.0
             },
             %{
               upstream_identity_id: ^visible_identity_id,
               requests: 1,
               traffic_share_percent: 25.0
             }
           ] = all_pools_dashboard.tables.upstreams

    assert Enum.sum(Enum.map(all_pools_dashboard.tables.upstreams, & &1.requests)) == 4

    refute Enum.any?(all_pools_dashboard.tables.upstreams, fn row ->
             row.upstream_identity_id == hidden_identity_id or
               row.upstream_label == "Hidden pool identity"
           end)

    refute Enum.any?(all_pools_dashboard.filters.pool_options, &(&1.name == "Stats Hidden"))

    assert {:ok, selected_pool_dashboard} =
             Stats.build_dashboard(admin_scope, %{
               pool_id: fixtures.pools.visible_a.id,
               window: "24h"
             })

    assert [
             %{
               upstream_identity_id: ^shared_identity_id,
               assignment_count: 1,
               requests: 2,
               traffic_share_percent: 100.0
             }
           ] = selected_pool_dashboard.tables.upstreams

    assert {:ok, owner_dashboard} = Stats.build_dashboard(fixtures.owner_scope, %{window: "24h"})
    assert Enum.sum(Enum.map(owner_dashboard.tables.upstreams, & &1.requests)) == 104

    assert owner_dashboard.tables.upstreams
           |> Map.new(&{&1.upstream_identity_id, &1.traffic_share_percent}) == %{
             hidden_identity_id => 96.2,
             shared_identity_id => 2.9,
             visible_identity_id => 1.0
           }
  end

  test "unassigned admins get explicit empty scoped stats" do
    %{user: owner} = bootstrap_owner_fixture()
    %{user: admin} = operator_fixture(owner, %{"email" => "stats-empty-admin@example.com"})
    pool = pool_fixture(%{slug: "stats-unassigned-hidden", name: "Stats Unassigned Hidden"})

    stats_usage_fixture(pool, 30, "Unassigned hidden key")

    admin_scope = Scope.for_user(admin)

    assert {:ok, dashboard} = Stats.build_dashboard(admin_scope, %{window: "24h"})

    assert dashboard.selected_pool == nil
    assert dashboard.filters.pool_options == []
    assert dashboard.kpis.requests.value == 0
    assert dashboard.kpis.tokens.total_tokens == 0
    assert dashboard.tables.top_api_keys == []
    assert dashboard.tables.upstreams == []
    assert dashboard.quota.accounts == []
    assert dashboard.charts.requests == []
    assert dashboard.charts.tokens == []
    assert dashboard.charts.settled_cost == []
    assert dashboard.sources.requests == 0
    assert dashboard.sources.settlements == 0
    assert [%{code: :no_reporting_pools}] = dashboard.empty_states

    assert {:error, %{code: :pool_not_found}} =
             Stats.build_dashboard(admin_scope, %{pool_id: pool.id, window: "24h"})
  end

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture()
    Scope.for_user(user, ["instance_owner"])
  end

  defp stats_usage_fixture(pool, total_tokens, api_key_display_name) do
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    stats_usage_for_assignment_fixture(pool, assignment, %{
      total_tokens: total_tokens,
      request_count: 1,
      api_key_display_name: api_key_display_name
    })
  end

  defp authorization_traffic_fixture do
    %{user: owner} = bootstrap_owner_fixture()
    owner_scope = Scope.for_user(owner, ["instance_owner"])

    %{user: admin} =
      operator_fixture(owner, %{
        "email" => "stats-auth-admin-#{System.unique_integer([:positive])}@example.com"
      })

    visible_a = pool_fixture(%{slug: "stats-auth-visible-a", name: "Stats Visible A"})
    visible_b = pool_fixture(%{slug: "stats-auth-visible-b", name: "Stats Visible B"})
    hidden = pool_fixture(%{slug: "stats-auth-hidden", name: "Stats Hidden"})

    operator_pool_assignment_fixture(admin, visible_a, created_by_user_id: owner.id)
    operator_pool_assignment_fixture(admin, visible_b, created_by_user_id: owner.id)

    %{identity: shared_identity, assignment: shared_assignment_a} =
      active_upstream_assignment_fixture(visible_a, %{
        account_label: "Shared identity",
        assignment_label: "Shared assignment"
      })

    shared_assignment_b =
      assignment_for_identity_fixture(visible_b, shared_identity, "Shared assignment")

    stats_usage_for_assignment_fixture(visible_a, shared_assignment_a, %{
      total_tokens: 20,
      request_count: 2,
      api_key_display_name: "Stats shared A"
    })

    stats_usage_for_assignment_fixture(visible_b, shared_assignment_b, %{
      total_tokens: 10,
      request_count: 1,
      api_key_display_name: "Stats shared B"
    })

    %{identity: visible_identity, assignment: visible_assignment} =
      upstream_assignment_fixture(visible_b, %{
        account_label: "Visible only identity",
        assignment_label: "Visible only assignment"
      })

    stats_usage_for_assignment_fixture(visible_b, visible_assignment, %{
      total_tokens: 10,
      request_count: 1,
      api_key_display_name: "Stats visible only"
    })

    %{identity: hidden_identity, assignment: hidden_assignment} =
      upstream_assignment_fixture(hidden, %{
        account_label: "Hidden pool identity",
        assignment_label: "Hidden pool assignment"
      })

    stats_usage_for_assignment_fixture(hidden, hidden_assignment, %{
      total_tokens: 100,
      request_count: 100,
      api_key_display_name: "Stats hidden"
    })

    %{
      owner_scope: owner_scope,
      admin_scope: Scope.for_user(admin),
      pools: %{visible_a: visible_a, visible_b: visible_b, hidden: hidden},
      shared_identity: shared_identity,
      visible_identity: visible_identity,
      hidden_identity: hidden_identity
    }
  end

  defp assignment_for_identity_fixture(pool, identity, assignment_label) do
    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label: assignment_label
             })

    assert {:ok, assignment} = PoolAssignments.activate_pool_assignment(assignment)
    assignment
  end

  defp stats_usage_for_assignment_fixture(pool, assignment, attrs) do
    attrs = Map.new(attrs)
    total_tokens = Map.fetch!(attrs, :total_tokens)
    request_count = Map.fetch!(attrs, :request_count)
    api_key_display_name = Map.fetch!(attrs, :api_key_display_name)

    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: api_key_display_name})

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        correlation_id: "stats-auth-#{System.unique_integer([:positive])}",
        requested_model: "gpt-stats-auth"
      })

    attempt = attempt_fixture(request, assignment)

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      total_tokens: total_tokens,
      input_tokens: total_tokens,
      output_tokens: 0,
      request_count: request_count,
      estimated_cost_micros: 0
    })
  end
end
