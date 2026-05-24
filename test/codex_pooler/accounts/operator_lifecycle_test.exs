defmodule CodexPooler.Accounts.OperatorLifecycleTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{Scope, Session, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Repo

  import CodexPooler.AccountsFixtures

  describe "operator lifecycle contract" do
    @tag :operator_lifecycle
    test "exports the expected public operator lifecycle APIs" do
      assert_operator_api!(:list_operators, 0)
      assert_operator_api!(:list_operators_for_management, 1)
      assert_operator_api!(:change_new_operator, 1)
      assert_operator_api!(:change_operator, 1)
      assert_operator_api!(:create_operator, 3)
      assert_operator_api!(:update_operator, 4)
      assert_operator_api!(:update_current_operator_profile, 3)
      assert_operator_api!(:deactivate_operator, 4)
      assert_operator_api!(:reactivate_operator, 4)
      assert_operator_api!(:reset_operator_password, 4)
      assert_operator_api!(:resend_operator_temporary_password, 4)
    end

    @tag :operator_lifecycle
    test "creates operators with normalized email, a valid temporary password, forced password change, and audit rows" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      create_changeset =
        call_operator_api!(:change_new_operator, [%{"email" => " Operator@Example.COM "}])

      assert Ecto.Changeset.apply_changes(create_changeset).email == "operator@example.com"

      assert {:ok, %{user: %User{} = operator, temporary_password: temporary_password}} =
               call_operator_api!(
                 :create_operator,
                 [
                   owner,
                   valid_operator_attributes(%{
                     "display_name" => "  Second Operator  ",
                     "email" => "  SECOND.OPERATOR@Example.COM  "
                   }),
                   operator_metadata(%{request_id: "operator-create-contract"})
                 ]
               )

      assert operator.email == "second.operator@example.com"
      assert operator.display_name == "Second Operator"
      assert operator.status == "active"
      assert operator.password_change_required == true

      assert Repo.get_by(Membership,
               user_id: operator.id,
               role: "instance_admin",
               status: "active"
             )

      assert is_binary(temporary_password)
      assert byte_size(temporary_password) >= 8
      refute operator.password_hash == temporary_password

      assert %Ecto.Changeset{} = call_operator_api!(:change_operator, [operator])

      assert Accounts.get_user_by_email_and_password(operator.email, temporary_password).id ==
               operator.id

      assert Enum.any?(call_operator_api!(:list_operators, []), &(&1.id == operator.id))

      assert {:ok, operators} =
               call_operator_api!(:list_operators_for_management, [owner])

      assert Enum.any?(operators, &(&1.id == operator.id))
      assert audit = Repo.get_by(AuditEvent, action: "operator.create", actor_user_id: owner.id)
      refute inspect(audit.details) =~ temporary_password
    end

    @tag :operator_lifecycle
    test "operator form changesets have explicit create and update contracts" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert %Ecto.Changeset{} =
               Accounts.change_new_operator(%{"email" => "new.operator@example.com"})

      assert %Ecto.Changeset{} = Accounts.change_operator(owner)

      assert_raise FunctionClauseError, fn ->
        Accounts.change_operator(%{"email" => "not-an-existing-operator@example.com"})
      end

      assert_raise FunctionClauseError, fn ->
        Accounts.change_new_operator(:invalid)
      end
    end

    @tag :operator_lifecycle
    test "honors an explicit false password-change requirement on create" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:ok, %{user: %User{} = operator, temporary_password: temporary_password}} =
               call_operator_api!(
                 :create_operator,
                 [
                   owner,
                   valid_operator_attributes(%{
                     "email" => "current-password.operator@example.com",
                     "password_change_required" => "false"
                   }),
                   operator_metadata(%{request_id: "operator-create-password-current-contract"})
                 ]
               )

      refute operator.password_change_required
      refute Repo.reload!(operator).password_change_required

      assert Accounts.get_user_by_email_and_password(operator.email, temporary_password).id ==
               operator.id
    end

    @tag :operator_lifecycle
    test "rejects duplicate normalized operator emails" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:ok, _result} =
               call_operator_api!(
                 :create_operator,
                 [
                   owner,
                   valid_operator_attributes(%{"email" => "Operator@Example.com"}),
                   operator_metadata()
                 ]
               )

      assert {:error, %Ecto.Changeset{} = changeset} =
               call_operator_api!(
                 :create_operator,
                 [
                   owner,
                   valid_operator_attributes(%{"email" => " operator@example.COM "}),
                   operator_metadata()
                 ]
               )

      assert %{email: [_ | _]} = errors_on(changeset)
    end

    @tag :operator_lifecycle
    test "rejects invalid manually supplied temporary passwords without auditing creation" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               call_operator_api!(
                 :create_operator,
                 [
                   owner,
                   valid_operator_attributes(%{
                     "email" => "operator@example.com",
                     "temporary_password" => "short"
                   }),
                   operator_metadata()
                 ]
               )

      assert %{password: ["should be at least 8 character(s)"]} = errors_on(changeset)
      refute Accounts.get_user_by_email("operator@example.com")
      refute Repo.get_by(AuditEvent, action: "operator.create", actor_user_id: owner.id)
    end

    @tag :operator_lifecycle
    test "operator lifecycle mutations require an instance owner actor" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: admin} = operator_fixture(owner, %{"email" => "admin@example.com"})
      %{user: target} = operator_fixture(owner, %{"email" => "target@example.com"})
      admin_scope = Scope.for_user(admin, ["instance_admin"])

      assert {:error, :operator_management_denied} =
               Accounts.list_operators_for_management(admin_scope)

      assert {:error, :operator_management_denied} =
               Accounts.create_operator(
                 admin_scope,
                 valid_operator_attributes(%{"email" => "denied-create@example.com"}),
                 operator_metadata(%{request_id: "operator-create-denied-contract"})
               )

      assert {:error, :operator_management_denied} =
               Accounts.update_operator(
                 admin_scope,
                 target,
                 %{"display_name" => "Denied Update"},
                 operator_metadata(%{request_id: "operator-update-denied-contract"})
               )

      assert {:error, :operator_management_denied} =
               Accounts.deactivate_operator(
                 admin_scope,
                 target,
                 %{"reason" => "denied"},
                 operator_metadata(%{request_id: "operator-deactivate-denied-contract"})
               )

      assert {:error, :operator_management_denied} =
               Accounts.reactivate_operator(
                 admin_scope,
                 target,
                 %{},
                 operator_metadata(%{request_id: "operator-reactivate-denied-contract"})
               )

      assert {:error, :operator_management_denied} =
               Accounts.reset_operator_password(
                 admin_scope,
                 target,
                 %{},
                 operator_metadata(%{request_id: "operator-reset-denied-contract"})
               )

      assert {:error, :operator_management_denied} =
               Accounts.resend_operator_temporary_password(
                 admin_scope,
                 target,
                 %{},
                 operator_metadata(%{request_id: "operator-resend-denied-contract"})
               )

      refute Accounts.get_user_by_email("denied-create@example.com")
      assert Repo.reload!(target).display_name == "Operator"
      assert Repo.reload!(target).status == "active"
      refute Repo.get_by(AuditEvent, action: "operator.update", actor_user_id: admin.id)
      refute Repo.get_by(AuditEvent, action: "operator.deactivate", actor_user_id: admin.id)
      refute Repo.get_by(AuditEvent, action: "operator.password_reset", actor_user_id: admin.id)
    end

    @tag :operator_lifecycle
    test "operator management uses active memberships instead of cached scope roles" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: admin} = operator_fixture(owner, %{"email" => "admin@example.com"})

      assert {:ok, operators} = Accounts.list_operators_for_management(Scope.for_user(owner, []))
      assert Enum.any?(operators, &(&1.id == owner.id))

      stale_owner_scope = Scope.for_user(admin, ["instance_owner"])

      assert {:error, :operator_management_denied} =
               Accounts.list_operators_for_management(stale_owner_scope)

      assert {:error, :operator_management_denied} =
               Accounts.create_operator(
                 stale_owner_scope,
                 valid_operator_attributes(%{"email" => "stale-owner-role@example.com"}),
                 operator_metadata(%{request_id: "operator-stale-role-denied-contract"})
               )

      refute Accounts.get_user_by_email("stale-owner-role@example.com")
    end

    @tag :operator_lifecycle
    test "current operator profile updates are self-service and limited to profile fields" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator} = operator_fixture(owner, %{"email" => "operator@example.com"})

      operator =
        operator
        |> Ecto.Changeset.change(password_change_required: false)
        |> Repo.update!()

      assert {:ok, %User{} = updated} =
               Accounts.update_current_operator_profile(
                 operator,
                 %{
                   "display_name" => "  Self Service Operator  ",
                   "email" => " SELF.SERVICE@Example.COM ",
                   "password_change_required" => true,
                   "status" => "disabled"
                 },
                 operator_metadata(%{request_id: "operator-profile-self-service"})
               )

      assert updated.id == operator.id
      assert updated.email == "self.service@example.com"
      assert updated.display_name == "Self Service Operator"
      assert updated.status == "active"
      assert updated.password_change_required == false

      assert audit =
               Repo.get_by(AuditEvent,
                 action: "operator.update",
                 actor_user_id: operator.id,
                 target_id: operator.id
               )

      assert audit.correlation_id == "operator-profile-self-service"
    end

    @tag :operator_lifecycle
    test "updates editable operator fields and persists password_change_required changes with audit rows" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator} = operator_fixture(owner, %{"email" => "operator@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, %User{} = updated} =
               call_operator_api!(
                 :update_operator,
                 [
                   scope,
                   operator.id,
                   %{
                     "display_name" => "  Updated Operator  ",
                     "email" => " UPDATED.OPERATOR@Example.COM ",
                     "password_change_required" => false
                   },
                   operator_metadata(%{request_id: "operator-update-contract"})
                 ]
               )

      assert updated.id == operator.id
      assert updated.email == "updated.operator@example.com"
      assert updated.display_name == "Updated Operator"
      assert updated.password_change_required == false
      assert Repo.get_by(AuditEvent, action: "operator.update", actor_user_id: owner.id)
    end

    @tag :operator_lifecycle
    test "deactivates operators, revokes their sessions, rejects inactive login, and reactivates them" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator, temporary_password: temporary_password} = operator_fixture(owner)

      assert {:ok, %{token: token}} =
               Accounts.login_user(%{"email" => operator.email, "password" => temporary_password})

      assert Accounts.get_user_by_session_token(token)

      assert {:ok, %User{} = disabled} =
               call_operator_api!(
                 :deactivate_operator,
                 [
                   owner,
                   operator,
                   %{"reason" => "offboarding"},
                   operator_metadata(%{request_id: "operator-deactivate-contract"})
                 ]
               )

      assert disabled.status == "disabled"
      refute Accounts.get_user_by_session_token(token)
      assert Repo.get_by(Session, user_id: operator.id, status: "revoked")

      assert {:error, :invalid_credentials} =
               Accounts.login_user(%{"email" => operator.email, "password" => temporary_password})

      assert Repo.get_by(AuditEvent, action: "operator.deactivate", actor_user_id: owner.id)

      assert {:ok, %{user: %User{} = reactivated, temporary_password: reactivated_password}} =
               call_operator_api!(
                 :reactivate_operator,
                 [
                   owner,
                   disabled,
                   %{"reason" => "returned"},
                   operator_metadata(%{request_id: "operator-reactivate-contract"})
                 ]
               )

      assert reactivated.status == "active"
      assert reactivated.password_change_required == true
      refute Accounts.get_user_by_email_and_password(operator.email, temporary_password)
      assert Accounts.get_user_by_email_and_password(operator.email, reactivated_password)
      assert Repo.get_by(AuditEvent, action: "operator.reactivate", actor_user_id: owner.id)
    end

    test "reactivation honors the submitted password-change requirement" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator, temporary_password: temporary_password} = operator_fixture(owner)

      assert {:ok, %User{} = disabled} =
               call_operator_api!(
                 :deactivate_operator,
                 [
                   owner,
                   operator,
                   %{"reason" => "temporary leave"},
                   operator_metadata(%{request_id: "operator-deactivate-reactivate-flag"})
                 ]
               )

      assert {:ok, %{user: %User{} = reactivated, temporary_password: reactivated_password}} =
               call_operator_api!(
                 :reactivate_operator,
                 [
                   owner,
                   disabled,
                   %{
                     "reason" => "returned",
                     "password_change_required" => false
                   },
                   operator_metadata(%{request_id: "operator-reactivate-flag-contract"})
                 ]
               )

      assert reactivated.status == "active"
      assert reactivated.password_change_required == false
      refute Accounts.get_user_by_email_and_password(operator.email, temporary_password)
      assert Accounts.get_user_by_email_and_password(operator.email, reactivated_password)
    end

    @tag :last_active_admin
    test "protects the last active admin from deactivation" do
      %{user: owner, token: token} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:error, :last_active_admin} =
               call_operator_api!(
                 :deactivate_operator,
                 [owner, owner, %{"reason" => "self-disable"}, operator_metadata()]
               )

      assert Repo.reload!(owner).status == "active"
      assert Accounts.get_user_by_session_token(token)
      refute Repo.get_by(AuditEvent, action: "operator.deactivate", actor_user_id: owner.id)
    end
  end

  defp assert_operator_api!(name, arity) do
    Code.ensure_loaded!(Accounts)

    assert function_exported?(Accounts, name, arity),
           "expected CodexPooler.Accounts.#{name}/#{arity} to define the operator lifecycle contract"
  end

  defp call_operator_api!(name, args) when is_atom(name) and is_list(args) do
    assert_operator_api!(name, length(args))
    apply(Accounts, name, args)
  end
end
