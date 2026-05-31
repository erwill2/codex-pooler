defmodule CodexPooler.Alerts.AlertsContextTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.{AlertChannel, AlertRule, AlertRuleChannel}
  alias CodexPooler.Repo

  test "owner and assigned admins list manageable active pool targets" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})

    assigned_pool =
      pool_fixture(%{slug: "alerts-target-assigned", name: "Alerts Target Assigned"})

    hidden_pool = pool_fixture(%{slug: "alerts-target-hidden", name: "Alerts Target Hidden"})

    disabled_pool =
      pool_fixture(%{
        slug: "alerts-target-disabled",
        name: "Alerts Target Disabled",
        status: "disabled"
      })

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)
    operator_pool_assignment_fixture(admin, disabled_pool, created_by_user_id: owner.id)

    assert {:ok, owner_pools} = Alerts.list_manageable_pools(owner_scope)
    owner_pool_ids = owner_pools |> Enum.map(& &1.id) |> MapSet.new()
    assert assigned_pool.id in owner_pool_ids
    assert hidden_pool.id in owner_pool_ids
    refute disabled_pool.id in owner_pool_ids

    assert {:ok, admin_pools} = Alerts.list_manageable_pools(Scope.for_user(admin))
    assert Enum.map(admin_pools, & &1.id) == [assigned_pool.id]
  end

  test "owner manages rules and channels through the Alerts facade" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: "alerts-owner-rule", name: "Alerts Owner Rule"})

    assert {:ok, channel} =
             Alerts.create_channel(owner_scope, %{
               channel_type: "webhook",
               display_name: "Webhook operations",
               state: "active",
               email_to: nil,
               endpoint_scheme: "https",
               endpoint_host: "hooks.example.com",
               endpoint_path_prefix: "/alerts",
               endpoint_fingerprint: "sha256:example",
               webhook_signing_secret_ciphertext: <<1, 2, 3>>,
               webhook_signing_secret_nonce: <<4, 5, 6>>,
               webhook_signing_secret_aad: %{"channel_id" => "pending"},
               webhook_signing_secret_key_version: "v1",
               metadata: %{}
             })

    refute Map.has_key?(channel, :webhook_signing_secret_ciphertext)
    refute Map.has_key?(channel, :webhook_signing_secret_nonce)
    refute Map.has_key?(channel, :webhook_signing_secret_aad)

    assert {:ok, rule} =
             Alerts.create_rule(
               owner_scope,
               rule_attrs(pool, %{display_name: "Owner coverage", channel_ids: [channel.id]})
             )

    assert rule.pool_id == pool.id
    assert rule.created_by_user_id == owner.id

    assert {:ok, [listed_rule]} = Alerts.list_rules(owner_scope, pool_id: pool.id)
    assert listed_rule.id == rule.id

    assert {:ok, updated_rule} = Alerts.update_rule(owner_scope, rule.id, %{state: "disabled"})
    assert updated_rule.state == "disabled"
    assert updated_rule.disabled_at

    assert {:ok, deleted_rule} = Alerts.delete_rule(owner_scope, updated_rule.id)
    assert deleted_rule.id == rule.id
    assert {:ok, []} = Alerts.list_rules(owner_scope, pool_id: pool.id)

    assert {:ok, deleted_channel} = Alerts.delete_channel(owner_scope, channel.id)
    assert deleted_channel.id == channel.id
  end

  test "assigned admins manage rules only for assigned pools" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)
    assigned_pool = pool_fixture(%{slug: "alerts-admin-assigned", name: "Alerts Admin Assigned"})
    hidden_pool = pool_fixture(%{slug: "alerts-admin-hidden", name: "Alerts Admin Hidden"})

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)

    assert {:ok, admin_rule} =
             Alerts.create_rule(
               admin_scope,
               rule_attrs(assigned_pool, %{display_name: "Admin rule"})
             )

    assert {:ok, _hidden_rule} =
             Alerts.create_rule(
               owner_scope,
               rule_attrs(hidden_pool, %{display_name: "Hidden rule"})
             )

    assert {:ok, [listed_rule]} = Alerts.list_rules(admin_scope)
    assert listed_rule.id == admin_rule.id

    assert {:ok, updated_rule} =
             Alerts.update_rule(admin_scope, admin_rule.id, %{display_name: "Admin rule updated"})

    assert updated_rule.display_name == "Admin rule updated"

    assert {:error, denied_create} =
             Alerts.create_rule(
               admin_scope,
               rule_attrs(hidden_pool, %{display_name: "Denied rule"})
             )

    assert denied_create.code == :capability_denied
    refute denied_create.message =~ hidden_pool.id
    refute denied_create.message =~ hidden_pool.name

    assert {:error, denied_filter} = Alerts.list_rules(admin_scope, pool_id: hidden_pool.id)
    assert denied_filter.code == :capability_denied
    refute denied_filter.message =~ hidden_pool.id
    refute denied_filter.message =~ hidden_pool.name

    assert {:ok, deleted_rule} = Alerts.delete_rule(admin_scope, admin_rule.id)
    assert deleted_rule.id == admin_rule.id
  end

  test "assigned admins manage only their own channels" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    %{user: other_admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)

    owner_channel =
      alert_channel_fixture(
        created_by_user_id: owner.id,
        display_name: "Owner private channel",
        email_to: "owner-alerts@example.com"
      )

    other_channel =
      alert_channel_fixture(
        created_by_user_id: other_admin.id,
        display_name: "Other private channel",
        email_to: "other-alerts@example.com"
      )

    assert {:ok, admin_channel} =
             Alerts.create_channel(admin_scope, %{
               channel_type: "email",
               display_name: "Admin owned channel",
               email_to: "alerts@example.com",
               metadata: %{}
             })

    assert admin_channel.created_by_user_id == admin.id

    assert {:ok, [listed_channel]} = Alerts.list_channels(admin_scope)
    assert listed_channel.id == admin_channel.id

    assert {:ok, updated_channel} =
             Alerts.update_channel(admin_scope, admin_channel.id, %{state: "disabled"})

    assert updated_channel.state == "disabled"

    assert {:error, update_error} =
             Alerts.update_channel(admin_scope, owner_channel.id, %{state: "disabled"})

    assert update_error.code == :channel_not_found
    refute update_error.message =~ owner_channel.display_name
    refute update_error.message =~ owner_channel.email_to

    assert {:error, delete_error} = Alerts.delete_channel(admin_scope, other_channel.id)
    assert delete_error.code == :channel_not_found
    refute delete_error.message =~ other_channel.display_name
    refute delete_error.message =~ other_channel.email_to

    assert %AlertChannel{state: "active"} = Repo.get(AlertChannel, owner_channel.id)
    assert %AlertChannel{state: "active"} = Repo.get(AlertChannel, other_channel.id)
    assert {:ok, deleted_channel} = Alerts.delete_channel(admin_scope, admin_channel.id)
    assert deleted_channel.id == admin_channel.id
  end

  test "assigned admins cannot attach hidden channels to rules" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)
    assigned_pool = pool_fixture(%{slug: "alerts-admin-channels", name: "Alerts Admin Channels"})
    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)

    admin_channel = alert_channel_fixture(created_by_user_id: admin.id)

    owner_channel =
      alert_channel_fixture(
        created_by_user_id: owner.id,
        display_name: "Owner hidden alerts",
        email_to: "hidden-owner-alerts@example.com"
      )

    assert {:ok, admin_rule} =
             Alerts.create_rule(
               admin_scope,
               rule_attrs(assigned_pool, %{
                 display_name: "Admin owned channel rule",
                 channel_ids: [admin_channel.id]
               })
             )

    assert 1 ==
             Repo.aggregate(
               from(link in AlertRuleChannel, where: link.alert_rule_id == ^admin_rule.id),
               :count,
               :id
             )

    before_rule_count = Repo.aggregate(from(rule in AlertRule), :count, :id)

    assert {:error, create_error} =
             Alerts.create_rule(
               admin_scope,
               rule_attrs(assigned_pool, %{
                 display_name: "Hidden channel rule",
                 channel_ids: [owner_channel.id]
               })
             )

    assert create_error.code == :channel_not_found
    refute create_error.message =~ owner_channel.display_name
    refute create_error.message =~ owner_channel.email_to
    assert Repo.aggregate(from(rule in AlertRule), :count, :id) == before_rule_count

    assert {:error, update_error} =
             Alerts.update_rule(admin_scope, admin_rule.id, %{channel_ids: [owner_channel.id]})

    assert update_error.code == :channel_not_found
    refute update_error.message =~ owner_channel.display_name
    refute update_error.message =~ owner_channel.email_to

    assert [%AlertRuleChannel{alert_channel_id: linked_channel_id}] =
             Repo.all(from link in AlertRuleChannel, where: link.alert_rule_id == ^admin_rule.id)

    assert linked_channel_id == admin_channel.id
  end

  test "pool-scoped incident actions require a manageable pool" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)

    assigned_pool =
      pool_fixture(%{slug: "alerts-action-assigned", name: "Alerts Action Assigned"})

    hidden_pool = pool_fixture(%{slug: "alerts-action-hidden", name: "Alerts Action Hidden"})

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)

    assigned_incident =
      alert_incident_fixture(
        pool: assigned_pool,
        dedupe_key: "alert:action:#{System.unique_integer([:positive])}"
      )

    hidden_incident =
      alert_incident_fixture(
        pool: hidden_pool,
        dedupe_key: "alert:hidden:#{System.unique_integer([:positive])}"
      )

    assert {:ok, acknowledged} = Alerts.acknowledge_incident(admin_scope, assigned_incident.id)
    assert acknowledged.state == "acknowledged"
    assert acknowledged.acknowledged_at

    assert {:ok, resolved} = Alerts.resolve_incident(owner_scope, acknowledged.id)
    assert resolved.state == "resolved"
    assert resolved.resolved_at

    assert {:error, hidden_error} = Alerts.acknowledge_incident(admin_scope, hidden_incident.id)
    assert hidden_error.code == :incident_not_found
    refute hidden_error.message =~ hidden_pool.id
    refute hidden_error.message =~ hidden_pool.name
  end

  defp rule_attrs(pool, overrides) do
    overrides = Map.new(overrides)

    %{
      pool_id: pool.id,
      scope_type: "pool",
      rule_kind: "pool_no_usable_assignments",
      display_name: Map.get(overrides, :display_name, "Pool usable assignment coverage"),
      severity: "critical",
      cooldown_minutes: 30,
      state: "active",
      metadata: %{}
    }
    |> Map.merge(overrides)
  end
end
