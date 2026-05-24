defmodule CodexPooler.DevFixtures.Operators do
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query
  require Logger

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{PlatformBootstrapState, Scope, TOTPSetting, User}
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Repo

  @count 100
  @email_domain "example.test"
  @owner_email "dev.owner@example.test"
  @fixture_password "dev-operator-pass-123!"
  @metadata %{
    ip_address: "127.0.0.1",
    user_agent: "codex-pooler-dev-fixtures/operators"
  }

  def run do
    Logger.configure(level: :info)

    owner = ensure_owner!()
    scope = Scope.for_user(owner, Accounts.roles_for_user(owner))

    result =
      1..@count
      |> Enum.map(&operator_attrs/1)
      |> Enum.map(&upsert_operator!(scope, &1))
      |> summarize()

    IO.puts("""
    Dev operator fixture complete.
    prefix=dev.operator
    created=#{result.created}
    updated=#{result.updated}
    total=#{result.total}
    active=#{result.active}
    disabled=#{result.disabled}
    mfa_enabled=#{result.mfa_enabled}
    mfa_disabled=#{result.mfa_disabled}
    password_change_required=#{result.password_change_required}
    password_change_not_required=#{result.password_change_not_required}
    """)
  end

  defp ensure_owner! do
    case owner_user() do
      %User{} = owner ->
        owner

      nil ->
        ensure_bootstrap_pending!()

        case Accounts.bootstrap_owner(
               %{
                 "email" => @owner_email,
                 "display_name" => "Dev Fixture Owner",
                 "password" => @fixture_password
               },
               @metadata
             ) do
          {:ok, %{user: owner}} -> owner
          {:error, reason} -> raise "failed to create dev fixture owner: #{inspect(reason)}"
        end
    end
  end

  defp ensure_bootstrap_pending! do
    case Repo.get(PlatformBootstrapState, true) do
      nil ->
        Repo.insert!(%PlatformBootstrapState{singleton: true, status: "pending"})

      %PlatformBootstrapState{status: "pending"} ->
        :ok

      %PlatformBootstrapState{status: status} ->
        raise "bootstrap state is #{status}, but no active instance owner exists"
    end
  end

  defp owner_user do
    Repo.one(
      from user in User,
        join: membership in Membership,
        on: membership.user_id == user.id,
        where:
          membership.role == "instance_owner" and membership.status == "active" and
            is_nil(user.deleted_at),
        order_by: [asc: user.id],
        limit: 1
    )
  end

  defp operator_attrs(index) do
    status = Enum.at(["active", "disabled"], rem(index - 1, 2))
    mfa_enabled? = rem(index, 2) == 0
    password_change_required? = rem(div(index - 1, 2), 2) == 0
    login_bucket = rem(index - 1, 4)

    %{
      index: index,
      email: "dev.operator.#{padded_index(index)}@#{@email_domain}",
      display_name: display_name(index, status, mfa_enabled?, password_change_required?),
      status: status,
      mfa_enabled?: mfa_enabled?,
      password_change_required?: password_change_required?,
      last_login_at: last_login_at(index, login_bucket)
    }
  end

  defp display_name(index, _status, _mfa_enabled?, _password_change_required?)
       when rem(index, 10) == 0,
       do: nil

  defp display_name(index, status, mfa_enabled?, password_change_required?) do
    mfa_label = if mfa_enabled?, do: "MFA on", else: "MFA off"
    password_label = if password_change_required?, do: "password reset", else: "password current"

    "Dev Operator #{padded_index(index)} - #{status} - #{mfa_label} - #{password_label}"
  end

  defp last_login_at(_index, 0), do: nil

  defp last_login_at(index, login_bucket) do
    DateTime.utc_now()
    |> DateTime.add(-(index * login_bucket * 3_600), :second)
    |> DateTime.truncate(:microsecond)
  end

  defp upsert_operator!(scope, attrs) do
    existing = Accounts.get_user_by_email(attrs.email)

    operator =
      if existing do
        update_existing_operator!(scope, existing, attrs)
      else
        create_operator!(scope, attrs)
      end

    operator =
      operator
      |> set_status!(attrs.status)
      |> set_last_login!(attrs.last_login_at)

    set_totp_state!(operator, attrs.mfa_enabled?)

    %{
      action: if(existing, do: :updated, else: :created),
      status: attrs.status,
      mfa_enabled?: attrs.mfa_enabled?,
      password_change_required?: attrs.password_change_required?
    }
  end

  defp create_operator!(scope, attrs) do
    case Accounts.create_operator(
           scope,
           %{
             "email" => attrs.email,
             "display_name" => attrs.display_name,
             "temporary_password" => @fixture_password,
             "password_change_required" => attrs.password_change_required?,
             "send_email" => false
           },
           @metadata
         ) do
      {:ok, %{user: operator}} -> operator
      {:error, reason} -> raise "failed to create #{attrs.email}: #{inspect(reason)}"
    end
  end

  defp update_existing_operator!(scope, operator, attrs) do
    case Accounts.update_operator(
           scope,
           operator,
           %{
             "email" => attrs.email,
             "display_name" => attrs.display_name,
             "password_change_required" => attrs.password_change_required?
           },
           @metadata
         ) do
      {:ok, operator} -> operator
      {:error, reason} -> raise "failed to update #{attrs.email}: #{inspect(reason)}"
    end
  end

  defp set_status!(operator, status) do
    operator
    |> change(status: status, updated_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp set_last_login!(operator, last_login_at) do
    operator
    |> change(last_login_at: last_login_at, updated_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp set_totp_state!(operator, true) do
    unless Accounts.totp_enabled?(operator) do
      {:ok, _result} = Accounts.enable_totp_for_user(operator)
    end
  end

  defp set_totp_state!(operator, false) do
    Repo.update_all(
      from(setting in TOTPSetting,
        where: setting.user_id == ^operator.id and setting.status == "active"
      ),
      set: [status: "disabled", disabled_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
    )
  end

  defp summarize(results) do
    Enum.reduce(
      results,
      %{
        created: 0,
        updated: 0,
        total: 0,
        active: 0,
        disabled: 0,
        mfa_enabled: 0,
        mfa_disabled: 0,
        password_change_required: 0,
        password_change_not_required: 0
      },
      fn result, summary ->
        summary
        |> Map.update!(result.action, &(&1 + 1))
        |> Map.update!(:total, &(&1 + 1))
        |> Map.update!(String.to_existing_atom(result.status), &(&1 + 1))
        |> Map.update!(mfa_key(result.mfa_enabled?), &(&1 + 1))
        |> Map.update!(password_key(result.password_change_required?), &(&1 + 1))
      end
    )
  end

  defp mfa_key(true), do: :mfa_enabled
  defp mfa_key(false), do: :mfa_disabled

  defp password_key(true), do: :password_change_required
  defp password_key(false), do: :password_change_not_required

  defp padded_index(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")
end

CodexPooler.DevFixtures.Operators.run()
