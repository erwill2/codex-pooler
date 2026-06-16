defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Sections do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents.Formatting

  def assignments_section(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="upstream-assignments"
      title="Pool assignments"
      description="Pools currently linked to this upstream account."
      count={Formatting.pluralize_count(@cockpit.assignments.count, "assignment", "assignments")}
    >
      <div :if={@cockpit.assignments.empty?} class="p-4">
        <AdminComponents.empty_state
          id="upstream-assignments-empty"
          title="No Pool assignments"
          description="This upstream account is visible but is not assigned to a Pool yet."
          icon="hero-link-slash"
        />
      </div>
      <div :if={!@cockpit.assignments.empty?} class="divide-y divide-base-300/70">
        <article
          :for={assignment <- @cockpit.assignments.items}
          id={"upstream-assignment-#{assignment.id}"}
          class="grid gap-3 p-4 md:grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)_auto] md:items-center"
        >
          <div class="grid min-w-0 gap-1">
            <h3 class="break-words text-sm font-semibold text-base-content">
              {assignment.assignment_label}
            </h3>
            <.link
              id={"upstream-assignment-#{assignment.id}-pool-link"}
              navigate={~p"/admin/pools"}
              class="break-words text-sm font-medium text-primary hover:underline"
            >
              {assignment.pool_label}
            </.link>
          </div>
          <div class="flex flex-wrap gap-2">
            <span class={Formatting.assignment_status_class(assignment.status)}>
              {Formatting.status_label("Assignment", assignment.status)}
            </span>
            <span class={Formatting.assignment_status_class(assignment.health_status)}>
              {Formatting.status_label("Health", assignment.health_status)}
            </span>
            <span class={Formatting.assignment_status_class(assignment.eligibility_status)}>
              {Formatting.status_label("Routing", assignment.eligibility_status)}
            </span>
            <span class={Formatting.assignment_status_class(assignment.quota_priming_status)}>
              {assignment.quota_priming_label}
            </span>
            <span
              :if={quota_item = quota_item_for(@cockpit, assignment)}
              class={Formatting.assignment_status_class(quota_item.state)}
            >
              {quota_assignment_label(quota_item)}
            </span>
            <span
              :if={contribution_item = pool_contribution_item_for(@cockpit, assignment)}
              class={Formatting.assignment_status_class(contribution_item.assignment_state)}
            >
              {contribution_item.assignment_state_label}
            </span>
          </div>
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/55">
            {assignment.quota_priming_label}
          </span>
        </article>
      </div>
    </AdminComponents.admin_surface>
    """
  end

  attr :cockpit, :map, required: true
  attr :datetime_preferences, :map, required: true

  def recent_events_section(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="upstream-event-summary"
      title="Recent events"
      description="Metadata-only summary of recent request and audit activity for this upstream."
      count={Formatting.pluralize_count(@cockpit.recent_events.count, "event", "events")}
    >
      <div class="grid gap-4 p-4">
        <p class="text-sm leading-6 text-base-content/70">
          {recent_events_description(@cockpit.recent_events)}
        </p>

        <div
          :if={@cockpit.recent_events.items != []}
          id="upstream-event-summary-rows"
          class="grid gap-3"
          role="list"
        >
          <article
            :for={event_row <- recent_event_rows(@cockpit.recent_events.items)}
            id={event_row.id}
            data-role="recent-event-row"
            class="grid gap-3 rounded-box border border-base-300 bg-base-200/45 p-3 md:grid-cols-[auto_minmax(0,1fr)_auto] md:items-center"
            role="listitem"
          >
            <div class="flex items-start md:justify-center">
              <span
                data-role="recent-event-source"
                class={event_source_badge_class(event_row.event.source)}
              >
                {event_source_label(event_row.event.source)}
              </span>
            </div>
            <div class="grid min-w-0 gap-1">
              <h3
                data-role="recent-event-title"
                class="break-words text-sm font-semibold text-base-content"
              >
                {event_row.event.title}
              </h3>
              <p
                data-role="recent-event-subtitle"
                class="break-words text-xs leading-5 text-base-content/65"
              >
                {event_row.event.subtitle}
              </p>
              <time
                data-role="recent-event-timestamp"
                datetime={DateTime.to_iso8601(event_row.event.timestamp)}
                class="text-xs font-medium text-base-content/55"
              >
                {Formatting.format_event_timestamp(event_row.event.timestamp, @datetime_preferences)}
              </time>
            </div>
            <.link
              data-role="recent-event-link"
              href={event_row.event.link}
              class="btn btn-ghost btn-xs justify-self-start gap-2 md:justify-self-end"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
              <span>Open evidence</span>
            </.link>
          </article>
        </div>

        <AdminComponents.empty_state
          :if={@cockpit.recent_events.items == []}
          id="upstream-event-summary-empty"
          title="No recent upstream events"
          description="Request and audit activity for this upstream account will appear here when the read model projects compact metadata events."
          icon="hero-clipboard-document-list"
        />
      </div>
      <:footer>
        <div class="flex flex-col gap-3 text-sm text-base-content/65 md:flex-row md:items-center md:justify-between">
          <p>
            For manual audit filtering, use upstream identity id <span class="font-mono">{@cockpit.identity.id}</span>.
          </p>
          <div class="flex flex-wrap gap-2">
            <.link
              id="upstream-event-summary-request-logs-link"
              href={Formatting.request_logs_path(@cockpit)}
              class="btn btn-secondary btn-xs gap-2"
            >
              <.icon name="hero-document-magnifying-glass" class="size-3.5" />
              <span>Filtered request logs</span>
            </.link>
            <.link
              id="upstream-event-summary-audit-logs-link"
              href={Formatting.audit_logs_path(@cockpit)}
              class="btn btn-secondary btn-xs gap-2"
            >
              <.icon name="hero-clipboard-document-list" class="size-3.5" />
              <span>Audit logs</span>
            </.link>
          </div>
        </div>
      </:footer>
    </AdminComponents.admin_surface>
    """
  end

  attr :cockpit, :map, required: true

  def actions_section(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="upstream-actions"
      title="Available actions"
      description="Bounded operator actions reuse the upstream account workflows and refresh this cockpit after successful mutations."
    >
      <div class="grid gap-3 p-4 sm:grid-cols-2 xl:grid-cols-3">
        <.cockpit_action_button
          id={"cockpit-rename-upstream-account-#{@cockpit.identity.id}"}
          label="Rename"
          icon="hero-pencil-square"
          action={@cockpit.actions.rename}
          phx-click="open_rename_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.cockpit_action_button
          id={"cockpit-pause-upstream-account-#{@cockpit.identity.id}"}
          label="Pause"
          icon="hero-pause"
          action={@cockpit.actions.pause}
          variant={:warning}
          phx-click="pause_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.cockpit_action_button
          id={"cockpit-reactivate-upstream-account-#{@cockpit.identity.id}"}
          label="Reactivate"
          icon="hero-play"
          action={@cockpit.actions.reactivate}
          variant={:positive}
          phx-click="reactivate_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.cockpit_action_button
          id={"cockpit-refresh-upstream-account-#{@cockpit.identity.id}"}
          label="Refresh token"
          icon="hero-arrow-path"
          action={@cockpit.actions.refresh_token}
          phx-click="refresh_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.cockpit_action_button
          id={"cockpit-replace-auth-json-upstream-account-#{@cockpit.identity.id}"}
          label="Replace auth.json"
          icon="hero-document-arrow-up"
          action={@cockpit.actions.replace_auth_json}
          phx-click="open_import_auth_json"
          phx-value-id={@cockpit.identity.id}
          phx-value-pool-id={default_pool_id(@cockpit)}
        />
        <.cockpit_action_button
          id={"cockpit-oauth-relink-upstream-account-#{@cockpit.identity.id}"}
          label="OAuth relink"
          icon="hero-link"
          action={@cockpit.actions.oauth_relink}
          variant={:primary}
          phx-click="open_oauth_relink"
          phx-value-id={@cockpit.identity.id}
        />
        <.cockpit_reinvite_link cockpit={@cockpit} />
        <.cockpit_action_button
          id={"cockpit-delete-upstream-account-#{@cockpit.identity.id}"}
          label="Delete"
          icon="hero-trash"
          action={@cockpit.actions.delete}
          variant={:danger}
          phx-click="open_delete_account"
          phx-value-id={@cockpit.identity.id}
        />
      </div>
      <:footer>
        <p class="text-sm text-base-content/65">
          Assignment and Pool changes stay on linked admin pages; this cockpit only mutates the upstream identity lifecycle and credentials.
        </p>
      </:footer>
    </AdminComponents.admin_surface>
    """
  end

  attr :cockpit, :map, required: true

  def related_links_section(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="upstream-related-links"
      title="Related admin pages"
      description="Use linked admin pages for full request and audit evidence."
    >
      <div class="flex flex-wrap gap-2 p-4">
        <.link
          href={Formatting.request_logs_path(@cockpit)}
          class="btn btn-secondary btn-sm gap-2"
        >
          <.icon name="hero-document-magnifying-glass" class="size-4" />
          <span>Request logs</span>
        </.link>
        <.link
          href={Formatting.audit_logs_path(@cockpit)}
          class="btn btn-secondary btn-sm gap-2"
        >
          <.icon name="hero-clipboard-document-list" class="size-4" />
          <span>Audit logs</span>
        </.link>
      </div>
    </AdminComponents.admin_surface>
    """
  end

  attr :cockpit, :map, required: true
  attr :refresh_data_message, :string, default: nil

  def refresh_section(assigns) do
    ~H"""
    <section
      id="upstream-refresh-data"
      class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">Refresh data</p>
          <h2 class="mt-1 text-lg font-semibold text-base-content">Refresh cockpit data</h2>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-base-content/65">
            Quota and upstream lifecycle changes refresh automatically when scoped broadcasts are available. Request health, recent events, and contribution metrics refresh only when this cockpit is reloaded.
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <span class="badge badge-outline">refresh {@cockpit.header.refresh_status}</span>
          <AdminComponents.action_button
            id="upstream-refresh-data-button"
            icon="hero-arrow-path"
            label="Refresh cockpit data"
            phx-click="refresh_data"
            variant={:primary}
          />
        </div>
      </div>
      <p
        :if={@refresh_data_message}
        id="upstream-refresh-data-message"
        class="mt-3 rounded-box border border-success/30 bg-success/10 px-3 py-2 text-sm font-medium text-success"
      >
        {@refresh_data_message}
      </p>
      <dl class="mt-4 grid gap-3 text-sm sm:grid-cols-2">
        <div>
          <dt class="text-xs font-semibold uppercase text-base-content/45">Auth imported</dt>
          <dd class="mt-1 text-base-content">{@cockpit.header.auth_fresh_label}</dd>
        </div>
        <div>
          <dt class="text-xs font-semibold uppercase text-base-content/45">Token refresh</dt>
          <dd class="mt-1 text-base-content">{@cockpit.header.token_refresh_label}</dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :action, :map, required: true
  attr :variant, :atom, default: :neutral
  attr :rest, :global, include: ~w(phx-click phx-value-id phx-value-pool-id)

  defp cockpit_action_button(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-200/60 p-3">
      <div class="flex items-center justify-between gap-2">
        <AdminComponents.action_button
          id={@id}
          icon={@icon}
          label={@label}
          variant={@variant}
          disabled={!@action.available?}
          title={@action.reason}
          {@rest}
        />
        <span class={action_state_class(@action)}>{action_state_label(@action)}</span>
      </div>
      <p :if={!@action.available? && @action.reason} class="mt-2 text-xs text-base-content/60">
        {@action.reason}
      </p>
    </div>
    """
  end

  attr :cockpit, :map, required: true

  defp cockpit_reinvite_link(assigns) do
    assigns = assign(assigns, :path, reinvite_path(assigns.cockpit))

    ~H"""
    <div class="rounded-box border border-base-300 bg-base-200/60 p-3">
      <div class="flex items-center justify-between gap-2">
        <AdminComponents.action_button
          :if={@path}
          id={"cockpit-reinvite-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-user-plus"
          label="Reinvite account"
          navigate={@path}
          disabled={!@cockpit.actions.reinvite.available?}
          title={@cockpit.actions.reinvite.reason}
        />
        <AdminComponents.action_button
          :if={!@path}
          id={"cockpit-reinvite-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-user-plus"
          label="Reinvite account"
          disabled
          title={@cockpit.actions.reinvite.reason}
        />
        <span class={action_state_class(@cockpit.actions.reinvite)}>
          {action_state_label(@cockpit.actions.reinvite)}
        </span>
      </div>
      <p
        :if={!@cockpit.actions.reinvite.available? && @cockpit.actions.reinvite.reason}
        class="mt-2 text-xs text-base-content/60"
      >
        {@cockpit.actions.reinvite.reason}
      </p>
    </div>
    """
  end

  defp default_pool_id(%{assignments: %{items: [%{pool_id: pool_id} | _items]}}), do: pool_id
  defp default_pool_id(_cockpit), do: nil

  defp reinvite_path(cockpit) do
    pool_id = default_pool_id(cockpit)

    if cockpit.actions.reinvite.available? and is_binary(pool_id) do
      ~p"/admin/invites?#{%{create: "1", pool_id: pool_id}}"
    end
  end

  defp recent_events_description(%{empty?: true}), do: "No recent upstream events"

  defp recent_events_description(%{count: count, degraded?: true}) do
    "#{Formatting.pluralize_count(count, "recent event", "recent events")} need operator review."
  end

  defp recent_events_description(%{count: count}) do
    "#{Formatting.pluralize_count(count, "recent event", "recent events")} are available on linked evidence pages."
  end

  defp recent_event_rows(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {event, index} ->
      %{id: "upstream-event-summary-row-#{index}", event: event}
    end)
  end

  defp event_source_label("request_log"), do: "request log"
  defp event_source_label("audit_log"), do: "audit log"
  defp event_source_label(source), do: source |> Formatting.status_text() |> String.downcase()

  defp event_source_badge_class("request_log"), do: "badge badge-info badge-sm"
  defp event_source_badge_class("audit_log"), do: "badge badge-primary badge-sm"
  defp event_source_badge_class(_source), do: "badge badge-neutral badge-sm"

  defp quota_item_for(cockpit, assignment) do
    Enum.find(cockpit.charts.quota_health.items, &(&1.assignment_id == assignment.id))
  end

  defp pool_contribution_item_for(cockpit, assignment) do
    Enum.find(cockpit.charts.pool_contribution.items, &(&1.assignment_id == assignment.id))
  end

  defp quota_assignment_label(%{state: "missing_evidence"}), do: "Quota missing"
  defp quota_assignment_label(%{state: "stale"}), do: "Quota refresh needed"
  defp quota_assignment_label(%{state: state}), do: Formatting.status_label("Quota", state)

  defp action_state_label(%{available?: true}), do: "available"
  defp action_state_label(_action), do: "not available"

  defp action_state_class(%{available?: true}), do: "badge badge-success"
  defp action_state_class(_action), do: "badge badge-neutral"
end
