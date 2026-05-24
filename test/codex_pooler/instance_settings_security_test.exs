defmodule CodexPooler.InstanceSettingsSecurityTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias CodexPooler.Audit
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  setup do
    Repo.delete_all(AuditEvent)
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  test "mcp service updates are audited as non-secret setting changes only", %{scope: scope} do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, updated} =
             InstanceSettings.update(settings, %{
               "mcp" => %{"enabled" => true},
               :current_scope => scope
             })

    assert updated.mcp.enabled == true

    event =
      Repo.one!(
        from audit in AuditEvent,
          where: audit.action == "instance_settings.update",
          order_by: [desc: audit.occurred_at],
          limit: 1
      )

    assert "mcp.enabled" in get_in(event.details, ["changed_keys"])
    assert "mcp" in get_in(event.details, ["changed_categories"])
    refute inspect(event.details) =~ "mcp-cxp"
    refute inspect(event.details) =~ "key_hash"
    refute inspect(event.details) =~ "key_prefix"
  end

  test "system save, remount, and audit details keep metrics and smtp secrets redacted", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    metrics_token = "security-metrics-token-#{System.unique_integer([:positive])}"
    smtp_password = "security-smtp-password-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "metrics"}}")

    metrics_html =
      view
      |> element("#instance-settings-metrics-form")
      |> render_submit(%{
        "instance_settings" => %{
          "metrics" => %{"bearer_token" => metrics_token}
        }
      })

    {:ok, smtp_view, _html} = live(conn, ~p"/admin/system")

    smtp_html =
      smtp_view
      |> element("#instance-settings-smtp-form")
      |> render_submit(%{
        "instance_settings" => %{
          "smtp" => %{
            "enabled" => "true",
            "host" => "smtp.example.com",
            "username" => "mailer",
            "from" => "sender@example.com",
            "password" => smtp_password
          }
        }
      })

    refute metrics_html =~ metrics_token
    refute smtp_html =~ smtp_password

    updated = InstanceSettings.get!()
    assert updated.metrics.bearer_token_status == :configured
    assert updated.smtp.password_status == :configured
    assert InstanceSettings.metrics_token_matches?(updated, metrics_token)
    assert {:ok, ^smtp_password} = InstanceSettings.decrypt_smtp_password(updated)

    events =
      Repo.all(
        from audit in AuditEvent,
          where: audit.action == "instance_settings.update" and audit.actor_user_id == ^user.id,
          order_by: [asc: audit.occurred_at, asc: audit.id]
      )

    metrics_event =
      Enum.find(events, fn event ->
        "metrics.bearer_token_configured" in get_in(event.details, ["changed_keys"])
      end)

    smtp_event =
      Enum.find(events, fn event ->
        "smtp.password_configured" in get_in(event.details, ["changed_keys"])
      end)

    assert metrics_event
    assert smtp_event

    assert get_in(metrics_event.details, ["credential_changes", "metrics_auth_state"]) ==
             "configured"

    assert get_in(metrics_event.details, ["credential_changes", "smtp_auth_state"]) ==
             "unchanged_unset"

    assert get_in(smtp_event.details, ["credential_changes", "metrics_auth_state"]) ==
             "unchanged_configured"

    assert get_in(smtp_event.details, ["credential_changes", "smtp_auth_state"]) == "configured"

    assert get_in(smtp_event.details, ["credential_changes", "metrics_fingerprint"]) ==
             updated.metrics.bearer_token_fingerprint

    for event <- events do
      refute inspect(event.details) =~ metrics_token
      refute inspect(event.details) =~ smtp_password
      refute Jason.encode!(event.details) =~ metrics_token
      refute Jason.encode!(event.details) =~ smtp_password
    end

    listed_events =
      scope
      |> Audit.list_events_for_scope(filters: [action: "instance_settings.update"])
      |> Map.fetch!(:items)
      |> Enum.filter(&(&1.actor_user_id == user.id))

    for listed_event <- listed_events do
      refute inspect(listed_event.details) =~ metrics_token
      refute inspect(listed_event.details) =~ smtp_password
      refute Jason.encode!(listed_event.details) =~ metrics_token
      refute Jason.encode!(listed_event.details) =~ smtp_password
    end

    {:ok, remounted_view, remounted_html} = live(conn, ~p"/admin/system?#{%{"tab" => "metrics"}}")

    refute remounted_html =~ metrics_token
    refute remounted_html =~ smtp_password
    assert has_element?(remounted_view, "#instance-settings-metrics-token-status", "configured")
    assert has_element?(remounted_view, "#instance-settings-metrics-token[value='']")
    assert remounted_html =~ updated.metrics.bearer_token_fingerprint

    {:ok, remounted_smtp_view, remounted_smtp_html} = live(conn, ~p"/admin/system")

    refute remounted_smtp_html =~ metrics_token
    refute remounted_smtp_html =~ smtp_password

    assert has_element?(
             remounted_smtp_view,
             "#instance-settings-smtp-password-status",
             "configured"
           )

    assert has_element?(remounted_smtp_view, "#instance-settings-smtp-password[value='']")
  end
end
