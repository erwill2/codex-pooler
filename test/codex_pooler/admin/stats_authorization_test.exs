defmodule CodexPooler.Admin.StatsAuthorizationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.Stats

  test "invalid and unauthorized scopes fail without returning data" do
    pool = pool_fixture(%{slug: "stats-invalid", name: "Stats Invalid"})
    scope = owner_scope()

    assert {:error, %{code: :invalid_window}} =
             Stats.build_dashboard(scope, %{window: "30d"})

    assert {:error, %{code: :pool_not_found}} =
             Stats.build_dashboard(scope, %{pool_id: Ecto.UUID.generate()})

    assert {:error, %{code: :unauthorized}} = Stats.build_dashboard(nil, %{pool_id: pool.id})
  end

  test "instance admins without pool.manage cannot build the global dashboard" do
    %{user: owner} = bootstrap_owner_fixture()
    %{user: admin} = operator_fixture(owner, %{"email" => "stats-admin@example.com"})
    admin_scope = Scope.for_user(admin, ["instance_admin"])

    assert {:error, %{code: :unauthorized}} = Stats.build_dashboard(admin_scope, %{})
  end

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture()
    Scope.for_user(user, ["instance_owner"])
  end
end
