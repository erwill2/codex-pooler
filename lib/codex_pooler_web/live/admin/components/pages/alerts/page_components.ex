defmodule CodexPoolerWeb.Admin.AlertsPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Alerts.Schemas.{AlertChannel, AlertIncident, AlertRule}
  alias CodexPoolerWeb.Admin.AlertChannelForm
  alias CodexPoolerWeb.Admin.AlertRuleForm
  alias CodexPoolerWeb.Admin.AlertsPageComponents
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolFilterComponents

  attr :selected_tab, :string, required: true

  def workspace_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end justify-between gap-3">
      <div>
        <p class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
          Alert management
        </p>
        <h2 class="text-lg font-semibold text-base-content">
          {workspace_title(@selected_tab)}
        </h2>
      </div>
      <div id="alerts-tabs" class="tabs tabs-border" role="tablist">
        <.link
          :for={tab <- alert_tabs()}
          id={"alerts-tab-#{tab.id}"}
          patch={~p"/admin/alerts?#{%{"tab" => tab.id}}"}
          role="tab"
          aria-selected={to_string(@selected_tab == tab.id)}
          class={["tab", @selected_tab == tab.id && "tab-active"]}
        >
          {tab.label}
        </.link>
      </div>
    </div>
    """
  end

  attr :selected_tab, :string, required: true
  attr :manageable_pools, :list, required: true
  attr :rules, :list, required: true
  attr :pool_lookup, :map, required: true
  attr :rule_form_mode, :atom, required: true
  attr :rule_form, :any, required: true

  def rules_section(assigns) do
    ~H"""
    <AdminComponents.extended_notice
      :if={@selected_tab == "rules" and @manageable_pools == []}
      id="alerts-no-manageable-pools-notice"
      icon="hero-server-stack"
      title="No manageable Pools"
      description="Ask an instance owner to assign an active Pool before creating alert rules."
      tone={:info}
    />

    <div
      :if={@selected_tab == "rules"}
      id="alerts-rules-section"
      class="grid min-w-0 gap-4 xl:grid-cols-[minmax(0,1fr)_24rem] xl:items-start"
    >
      <AdminComponents.admin_surface
        id="alerts-rules-list"
        title="Rules"
        description="Pool-first alert definitions evaluated from persisted metadata only."
        count={rule_count_label(@rules)}
        overflow={:visible}
      >
        <AdminComponents.empty_state
          :if={@rules == []}
          id="alerts-rules-empty-state"
          title="No alert rules"
          description="Create a rule for an active Pool to start tracking serving risk and quota evidence."
          icon="hero-bell-alert"
        />

        <div :if={@rules != []} id="alerts-rule-table-scroll-region" class="overflow-x-auto">
          <table id="alerts-rule-table" class="table min-w-[52rem]">
            <thead>
              <tr>
                <th>Rule</th>
                <th>Pool</th>
                <th class="text-center">State</th>
                <th>Threshold</th>
                <th class="text-center">Cooldown</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={rule <- @rules}
                id={"alert-rule-row-#{rule.id}"}
                class="text-sm transition-colors hover:bg-base-200/80"
              >
                <td class="min-w-56">
                  <div class="grid min-w-0 gap-1">
                    <span class="truncate font-semibold text-base-content">
                      {rule.display_name}
                    </span>
                    <span
                      id={"alert-rule-row-#{rule.id}-kind"}
                      class="text-xs text-base-content/60"
                    >
                      {AlertRuleForm.rule_kind_label(rule.rule_kind)}
                    </span>
                  </div>
                </td>
                <td class="min-w-44">
                  <div class="grid min-w-0 gap-0.5">
                    <span id={"alert-rule-row-#{rule.id}-pool"} class="truncate font-medium">
                      {pool_name_for(@pool_lookup, rule.pool_id)}
                    </span>
                    <span class="truncate font-mono text-xs text-base-content/45">
                      {pool_slug_for(@pool_lookup, rule.pool_id)}
                    </span>
                  </div>
                </td>
                <td class="text-center">
                  <span
                    id={"alert-rule-row-#{rule.id}-state"}
                    class={AdminBadges.status_chip_class(rule.state)}
                  >
                    {AlertRuleForm.state_label(rule.state)}
                  </span>
                </td>
                <td
                  id={"alert-rule-row-#{rule.id}-threshold"}
                  class="min-w-40 text-xs text-base-content/70"
                >
                  {threshold_summary(rule)}
                </td>
                <td
                  id={"alert-rule-row-#{rule.id}-cooldown"}
                  class="text-center font-mono text-xs tabular-nums text-base-content/70"
                >
                  {rule.cooldown_minutes} min
                </td>
                <td class="text-right">
                  <div class="flex justify-end gap-2">
                    <AdminComponents.action_button
                      id={"alert-rule-edit-#{rule.id}"}
                      icon="hero-pencil-square"
                      label="Edit"
                      phx-click="open_edit_rule"
                      phx-value-id={rule.id}
                    />
                    <AdminComponents.action_button
                      :if={rule.state == AlertRule.active_state()}
                      id={"alert-rule-disable-#{rule.id}"}
                      icon="hero-pause"
                      label="Disable"
                      phx-click="disable_rule"
                      phx-value-id={rule.id}
                    />
                    <AdminComponents.action_button
                      id={"alert-rule-delete-#{rule.id}"}
                      icon="hero-trash"
                      label="Delete"
                      phx-click="open_delete_rule"
                      phx-value-id={rule.id}
                      variant={:danger}
                    />
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </AdminComponents.admin_surface>

      <AdminComponents.admin_surface
        id="alerts-rule-form-panel"
        title={rule_form_title(@rule_form_mode)}
        description="Choose a manageable Pool first, then configure the rule condition."
        overflow={:visible}
      >
        <.form
          id="alerts-rule-form"
          for={@rule_form}
          phx-change="change_rule_form"
          phx-submit="save_rule"
          autocomplete="off"
          class="grid gap-4 p-4"
        >
          <.input field={@rule_form[:scope_type]} type="hidden" />
          <div class="grid gap-4">
            <.input
              id="alert-rule-pool-id"
              field={@rule_form[:pool_id]}
              type="select"
              label="Pool"
              options={AlertRuleForm.pool_options(@manageable_pools)}
              prompt="Choose Pool"
              required
              disabled={@manageable_pools == []}
            />
            <.input
              id="alert-rule-display-name"
              field={@rule_form[:display_name]}
              type="text"
              label="Rule name"
              placeholder="Primary Pool serving risk"
              required
            />
            <.input
              id="alert-rule-kind"
              field={@rule_form[:rule_kind]}
              type="select"
              label="Condition"
              options={AlertRuleForm.rule_kind_options()}
              required
            />
          </div>

          <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-1">
            <.input
              id="alert-rule-severity"
              field={@rule_form[:severity]}
              type="select"
              label="Severity"
              options={AlertRuleForm.severity_options()}
            />
            <.input
              id="alert-rule-state"
              field={@rule_form[:state]}
              type="select"
              label="Rule state"
              options={AlertRuleForm.state_options()}
            />
            <.input
              id="alert-rule-cooldown-minutes"
              field={@rule_form[:cooldown_minutes]}
              type="number"
              label="Cooldown minutes"
              min={AlertRule.cooldown_minimum_minutes()}
              max={AlertRule.cooldown_maximum_minutes()}
              required
            />
            <.input
              id="alert-rule-model"
              field={@rule_form[:model]}
              type="text"
              label="Model filter"
              placeholder="Optional model id"
            />
          </div>

          <div
            id="alert-rule-kind-fields"
            class="grid gap-4 rounded-box border border-base-300 bg-base-200 p-4"
          >
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
              Rule-specific fields
            </p>

            <.input
              :if={AlertRuleForm.value(@rule_form[:rule_kind]) == "pool_low_usable_assignments"}
              id="alert-rule-min-usable-assignments"
              field={@rule_form[:min_usable_assignments]}
              type="number"
              label="Minimum usable assignments"
              min="1"
            />

            <.input
              :if={
                AlertRuleForm.value(@rule_form[:rule_kind]) == "pool_all_assignments_in_state" ||
                  AlertRuleForm.value(@rule_form[:rule_kind]) == "upstream_auth_state"
              }
              id="alert-rule-target-state"
              field={@rule_form[:target_state]}
              type="select"
              label="Target state"
              options={
                AlertRuleForm.target_state_options(AlertRuleForm.value(@rule_form[:rule_kind]))
              }
            />

            <.input
              :if={AlertRuleForm.value(@rule_form[:rule_kind]) == "upstream_quota_threshold"}
              id="alert-rule-window-selector"
              field={@rule_form[:window_selector]}
              type="select"
              label="Quota window"
              options={AlertRuleForm.window_selector_options()}
            />

            <.input
              :if={AlertRuleForm.value(@rule_form[:rule_kind]) == "upstream_quota_threshold"}
              id="alert-rule-threshold-used-percent"
              field={@rule_form[:threshold_used_percent]}
              type="number"
              label="Used threshold percent"
              min="0"
              max="100"
              step="0.1"
            />

            <p
              :if={AlertRuleForm.value(@rule_form[:rule_kind]) == "pool_no_usable_assignments"}
              id="alert-rule-no-extra-fields"
              class="text-sm leading-6 text-base-content/65"
            >
              This rule fires when the selected Pool has no usable upstream assignments for the optional model filter.
            </p>
          </div>

          <div class="flex flex-wrap justify-end gap-2">
            <AdminComponents.action_button
              id="alert-rule-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_rule_form"
            />
            <AdminComponents.action_button
              id="alert-rule-submit"
              icon="hero-check"
              label={rule_form_submit_label(@rule_form_mode)}
              type="submit"
              variant={:primary}
              disabled={@manageable_pools == []}
            />
          </div>
        </.form>
      </AdminComponents.admin_surface>
    </div>
    """
  end

  attr :selected_tab, :string, required: true
  attr :channels, :list, required: true
  attr :channel_form_mode, :atom, required: true
  attr :channel_form, :any, required: true
  attr :editing_channel, :any, default: nil

  def channels_section(assigns) do
    ~H"""
    <div
      :if={@selected_tab == "channels"}
      id="alerts-channels-section"
      class="grid min-w-0 gap-4 xl:grid-cols-[minmax(0,1fr)_24rem] xl:items-start"
    >
      <AdminComponents.admin_surface
        id="alerts-channels-list"
        title="Channels"
        description="Email and webhook delivery targets with write-only endpoint secrets."
        count={channel_count_label(@channels)}
        overflow={:visible}
      >
        <AdminComponents.empty_state
          :if={@channels == []}
          id="alerts-channels-empty-state"
          title="No alert channels"
          description="Create an email or webhook channel before linking alerts to delivery targets."
          icon="hero-paper-airplane"
        />

        <div
          :if={@channels != []}
          id="alerts-channel-table-scroll-region"
          class="overflow-x-auto"
        >
          <table id="alerts-channel-table" class="table min-w-[56rem]">
            <thead>
              <tr>
                <th>Channel</th>
                <th>Endpoint</th>
                <th class="text-center">State</th>
                <th>Secret</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={channel <- @channels}
                id={"alert-channel-row-#{channel.id}"}
                class="text-sm transition-colors hover:bg-base-200/80"
              >
                <td class="min-w-52">
                  <div class="grid min-w-0 gap-1">
                    <span class="truncate font-semibold text-base-content">
                      {channel.display_name}
                    </span>
                    <span
                      id={"alert-channel-row-#{channel.id}-type"}
                      class="text-xs text-base-content/60"
                    >
                      {AlertChannelForm.channel_type_label(channel.channel_type)}
                    </span>
                  </div>
                </td>
                <td id={"alert-channel-row-#{channel.id}-endpoint"} class="min-w-64">
                  <div class="grid min-w-0 gap-1">
                    <span class="break-all font-mono text-xs text-base-content/75">
                      {channel_endpoint_label(channel)}
                    </span>
                    <span
                      :if={channel.endpoint_fingerprint}
                      id={"alert-channel-row-#{channel.id}-fingerprint"}
                      class="font-mono text-xs text-base-content/45"
                    >
                      Fingerprint {channel.endpoint_fingerprint}
                    </span>
                  </div>
                </td>
                <td class="text-center">
                  <span
                    id={"alert-channel-row-#{channel.id}-state"}
                    class={AdminBadges.status_chip_class(channel.state)}
                  >
                    {AlertChannelForm.state_label(channel.state)}
                  </span>
                </td>
                <td
                  id={"alert-channel-row-#{channel.id}-secret"}
                  class="text-xs text-base-content/70"
                >
                  Signing secret {AlertChannelForm.secret_status_label(
                    channel.webhook_signing_secret_key_version
                  )}
                </td>
                <td class="text-right">
                  <div class="flex justify-end gap-2">
                    <AdminComponents.action_button
                      id={"alert-channel-edit-#{channel.id}"}
                      icon="hero-pencil-square"
                      label="Edit"
                      phx-click="open_edit_channel"
                      phx-value-id={channel.id}
                    />
                    <AdminComponents.action_button
                      :if={channel.state == AlertChannel.active_state()}
                      id={"alert-channel-disable-#{channel.id}"}
                      icon="hero-pause"
                      label="Disable"
                      phx-click="disable_channel"
                      phx-value-id={channel.id}
                    />
                    <AdminComponents.action_button
                      id={"alert-channel-delete-#{channel.id}"}
                      icon="hero-trash"
                      label="Delete"
                      phx-click="open_delete_channel"
                      phx-value-id={channel.id}
                      variant={:danger}
                    />
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </AdminComponents.admin_surface>

      <AdminComponents.admin_surface
        id="alerts-channel-form-panel"
        title={channel_form_title(@channel_form_mode)}
        description="Store delivery endpoints without revealing full webhook URLs or signing secrets after save."
        overflow={:visible}
      >
        <.form
          id="alerts-channel-form"
          for={@channel_form}
          phx-change="change_channel_form"
          phx-submit="save_channel"
          autocomplete="off"
          class="grid gap-4 p-4"
        >
          <input
            :if={@channel_form_mode == :edit}
            type="hidden"
            name="alert_channel[channel_type]"
            value={AlertChannelForm.value(@channel_form[:channel_type])}
          />
          <div class="grid gap-4">
            <.input
              id="alert-channel-display-name"
              field={@channel_form[:display_name]}
              type="text"
              label="Channel name"
              placeholder="Operations alerts"
              required
            />
            <.input
              id="alert-channel-type"
              field={@channel_form[:channel_type]}
              type="select"
              label="Channel type"
              options={AlertChannelForm.channel_type_options()}
              disabled={@channel_form_mode == :edit}
              required
            />
            <.input
              id="alert-channel-state"
              field={@channel_form[:state]}
              type="select"
              label="Channel state"
              options={AlertChannelForm.state_options()}
            />
          </div>

          <div
            id="alert-channel-kind-fields"
            class="grid gap-4 rounded-box border border-base-300 bg-base-200 p-4"
          >
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
              Delivery endpoint
            </p>

            <.input
              :if={AlertChannelForm.value(@channel_form[:channel_type]) == "email"}
              id="alert-channel-email-to"
              field={@channel_form[:email_to]}
              type="email"
              label="Email recipient"
              placeholder="alerts@example.com"
              required
            />

            <div
              :if={AlertChannelForm.value(@channel_form[:channel_type]) == "webhook"}
              class="grid gap-4"
            >
              <.input
                id="alert-channel-webhook-url"
                field={@channel_form[:endpoint_url]}
                type="url"
                label="Webhook URL"
                placeholder={webhook_url_placeholder(@channel_form_mode)}
                required={@channel_form_mode == :create}
              />
              <div class="grid gap-2">
                <.input
                  id="alert-channel-webhook-signing-secret"
                  field={@channel_form[:webhook_signing_secret]}
                  type="password"
                  label="Signing secret"
                  placeholder="Leave blank to preserve"
                  autocomplete="new-password"
                />
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <p
                    id="alert-channel-webhook-signing-secret-status"
                    class="text-xs leading-5 text-base-content/60"
                  >
                    Stored signing secret:
                    <span class="font-semibold text-base-content/70">
                      {channel_form_secret_status(@editing_channel)}
                    </span>
                  </p>
                  <input
                    type="hidden"
                    name="alert_channel[webhook_signing_secret_action]"
                    value="preserve"
                  />
                  <label class="flex cursor-pointer items-center gap-2 text-xs font-medium text-base-content/70">
                    <input
                      id="alert-channel-webhook-signing-secret-clear"
                      type="checkbox"
                      name="alert_channel[webhook_signing_secret_action]"
                      value="clear"
                      checked={
                        AlertChannelForm.value(@channel_form[:webhook_signing_secret_action]) ==
                          "clear"
                      }
                      class="checkbox checkbox-primary checkbox-sm"
                    /> Clear stored signing secret
                  </label>
                </div>
              </div>
              <p
                id="alert-channel-webhook-url-help"
                class="text-xs leading-5 text-base-content/55"
              >
                After save, only scheme, host, masked path prefix, fingerprint, and key-version metadata are shown.
              </p>
            </div>
          </div>

          <div class="flex flex-wrap justify-end gap-2">
            <AdminComponents.action_button
              id="alert-channel-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_channel_form"
            />
            <AdminComponents.action_button
              id="alert-channel-submit"
              icon="hero-check"
              label={channel_form_submit_label(@channel_form_mode)}
              type="submit"
              variant={:primary}
            />
          </div>
        </.form>
      </AdminComponents.admin_surface>
    </div>
    """
  end

  attr :selected_tab, :string, required: true
  attr :incident_filter_form, :any, required: true
  attr :incident_filter_values, :map, required: true
  attr :incident_pool_filter_options, :list, required: true
  attr :incident_severity_filter_options, :list, required: true
  attr :incident_state_filter_options, :list, required: true
  attr :incident_rule_filter_options, :list, required: true
  attr :incident_channel_filter_options, :list, required: true
  attr :incident_filter_errors, :list, required: true
  attr :incidents, :list, required: true
  attr :incident_total_count, :integer, required: true
  attr :incident_page_size, :integer, required: true

  def incidents_section(assigns) do
    ~H"""
    <div
      :if={@selected_tab == "incidents"}
      id="alerts-incidents-section"
      class="grid min-w-0 gap-4"
    >
      <AdminComponents.admin_surface
        id="alerts-incidents-filters"
        title="Incident filters"
        description="Filter persisted alert incidents without exposing hidden Pool impact or raw evidence keys."
        overflow={:visible}
      >
        <AdminComponents.filter_form
          id="alerts-incidents-filter-form"
          for={@incident_filter_form}
          phx-submit="filter_incidents"
          compact
          mobile_single_column
        >
          <PoolFilterComponents.pool_filter_dropdown
            id="alerts-incident-pool-filter"
            label="Impacted Pool"
            hidden_id="alerts-incident-pool-id"
            event="select_incident_pool_filter"
            selected_value={@incident_filter_values["pool_id"] || ""}
            options={@incident_pool_filter_options}
          />
          <.input
            id="alerts-incident-severity-filter"
            field={@incident_filter_form[:severity]}
            type="select"
            label="Severity"
            options={option_tuples(@incident_severity_filter_options)}
          />
          <.input
            id="alerts-incident-state-filter"
            field={@incident_filter_form[:state]}
            type="select"
            label="State"
            options={option_tuples(@incident_state_filter_options)}
          />
          <:advanced>
            <.input
              id="alerts-incident-rule-filter"
              field={@incident_filter_form[:rule_id]}
              type="select"
              label="Rule"
              options={option_tuples(@incident_rule_filter_options)}
            />
            <.input
              id="alerts-incident-channel-filter"
              field={@incident_filter_form[:channel_id]}
              type="select"
              label="Channel"
              options={option_tuples(@incident_channel_filter_options)}
            />
          </:advanced>
          <:actions>
            <AdminComponents.action_button
              id="alerts-incidents-filter-submit"
              icon="hero-funnel"
              label="Apply"
              type="submit"
              variant={:primary}
            />
            <.link
              id="alerts-incidents-filter-clear"
              patch={~p"/admin/alerts?#{%{"tab" => "incidents"}}"}
              class="btn btn-secondary btn-sm"
            >
              Clear
            </.link>
          </:actions>
        </AdminComponents.filter_form>

        <div
          :if={@incident_filter_errors != []}
          id="alerts-incidents-filter-errors"
          class="mt-3 grid gap-2"
        >
          <p
            :for={error <- @incident_filter_errors}
            id={"alerts-incidents-filter-error-#{error.field}"}
            class="text-sm text-error"
          >
            {error.message}
          </p>
        </div>
      </AdminComponents.admin_surface>

      <AdminComponents.admin_surface
        id="alerts-incidents-list"
        title="Incidents"
        description="Recent alert incidents projected through the current operator's Pool visibility."
        count={incident_count_label(@incident_total_count, @incident_page_size)}
        overflow={:visible}
      >
        <AdminComponents.empty_state
          :if={@incidents == []}
          id="alerts-incidents-empty-state"
          title="No alert incidents"
          description="No visible alert incidents match the selected filters."
          icon="hero-bell-alert"
        />

        <div
          :if={@incidents != []}
          id="alerts-incident-table-scroll-region"
          class="hidden overflow-x-auto lg:block"
        >
          <table id="alerts-incident-table" class="table min-w-[84rem]">
            <thead>
              <tr>
                <th>Incident</th>
                <th>Impacted Pools</th>
                <th class="text-center">Severity</th>
                <th class="text-center">State</th>
                <th>Delivery</th>
                <th class="text-right">Last seen</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={incident <- @incidents}
                id={"alert-incident-#{incident.id}"}
                class="text-sm transition-colors hover:bg-base-200/80"
                data-role="alert-incident-row"
                data-alert-anchor-id={"alert-incident-#{incident.id}"}
              >
                <td class="min-w-72">
                  <div class="grid min-w-0 gap-1">
                    <span
                      id={"alert-incident-row-#{incident.id}-reason"}
                      data-role="incident-reason"
                      class="font-semibold text-base-content"
                    >
                      {incident.reason_title}
                    </span>
                    <span
                      id={"alert-incident-row-#{incident.id}-kind"}
                      data-role="incident-kind"
                      class="text-xs text-base-content/60"
                    >
                      {incident.rule_kind_label}
                    </span>
                    <span
                      id={"alert-incident-row-#{incident.id}-detail"}
                      data-role="incident-detail"
                      class="text-xs leading-5 text-base-content/55"
                    >
                      {incident.reason_detail}
                    </span>
                  </div>
                </td>
                <td class="min-w-64">
                  <AlertsPageComponents.impacted_pool_list
                    incident={incident}
                    prefix="alert-incident-row"
                  />
                </td>
                <td class="text-center">
                  <span
                    id={"alert-incident-row-#{incident.id}-severity"}
                    data-role="incident-severity"
                    class={AlertsPageComponents.severity_chip_class(incident.severity)}
                  >
                    {incident.severity_label}
                  </span>
                </td>
                <td class="text-center">
                  <span
                    id={"alert-incident-row-#{incident.id}-state"}
                    data-role="incident-state"
                    class={AdminBadges.status_chip_class(incident.state)}
                  >
                    {incident.state_label}
                  </span>
                </td>
                <td
                  id={"alert-incident-row-#{incident.id}-delivery"}
                  class="min-w-64 text-xs text-base-content/70"
                >
                  <AlertsPageComponents.incident_delivery_summary
                    incident={incident}
                    prefix="alert-incident-row"
                  />
                </td>
                <td
                  id={"alert-incident-row-#{incident.id}-last-seen"}
                  class="text-right font-mono text-xs tabular-nums text-base-content/60"
                >
                  {AlertsPageComponents.format_datetime(incident.last_seen_at)}
                </td>
                <td class="text-right">
                  <AlertsPageComponents.incident_action_controls
                    incident={incident}
                    prefix="alert-incident"
                  />
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@incidents != []} id="alerts-incident-cards" class="grid gap-3 lg:hidden">
          <article
            :for={incident <- @incidents}
            id={"alert-incident-card-#{incident.id}"}
            class="rounded-box border border-base-300 bg-base-100 p-4 shadow-sm"
          >
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="grid min-w-0 gap-1">
                <h3
                  id={"alert-incident-card-#{incident.id}-reason"}
                  class="font-semibold text-base-content"
                >
                  {incident.reason_title}
                </h3>
                <p
                  id={"alert-incident-card-#{incident.id}-kind"}
                  class="text-xs text-base-content/60"
                >
                  {incident.rule_kind_label}
                </p>
              </div>
              <div class="flex flex-wrap gap-2">
                <span
                  id={"alert-incident-card-#{incident.id}-severity"}
                  data-role="incident-severity"
                  class={AlertsPageComponents.severity_chip_class(incident.severity)}
                >
                  {incident.severity_label}
                </span>
                <span
                  id={"alert-incident-card-#{incident.id}-state"}
                  data-role="incident-state"
                  class={AdminBadges.status_chip_class(incident.state)}
                >
                  {incident.state_label}
                </span>
              </div>
            </div>
            <p
              id={"alert-incident-card-#{incident.id}-detail"}
              class="mt-3 text-sm leading-6 text-base-content/65"
            >
              {incident.reason_detail}
            </p>
            <div class="mt-3 grid gap-3 text-sm">
              <AlertsPageComponents.impacted_pool_list
                incident={incident}
                prefix="alert-incident-card"
              />
              <div
                id={"alert-incident-card-#{incident.id}-delivery"}
                class="text-xs text-base-content/70"
              >
                <AlertsPageComponents.incident_delivery_summary
                  incident={incident}
                  prefix="alert-incident-card"
                />
              </div>
              <p
                id={"alert-incident-card-#{incident.id}-last-seen"}
                class="font-mono text-xs text-base-content/55"
              >
                Last seen {AlertsPageComponents.format_datetime(incident.last_seen_at)}
              </p>
              <AlertsPageComponents.incident_action_controls
                incident={incident}
                prefix="alert-incident-card"
              />
            </div>
          </article>
        </div>
      </AdminComponents.admin_surface>
    </div>
    """
  end

  defp alert_tabs do
    [
      %{id: "rules", label: "Rules"},
      %{id: "channels", label: "Channels"},
      %{id: "incidents", label: "Incidents"}
    ]
  end

  defp workspace_title("channels"), do: "Channels"
  defp workspace_title("incidents"), do: "Incidents"
  defp workspace_title(_tab), do: "Rules"

  defp option_tuples(options), do: Enum.map(options, &{&1.label, &1.value})

  defp incident_count_label(0, _page_size), do: "0 incidents"
  defp incident_count_label(1, _page_size), do: "1 incident"

  defp incident_count_label(total, page_size) when total > page_size,
    do: "#{page_size} of #{total} incidents"

  defp incident_count_label(total, _page_size), do: "#{total} incidents"

  defp rule_form_title(:edit), do: "Edit rule"
  defp rule_form_title(_mode), do: "Create rule"

  defp rule_form_submit_label(:edit), do: "Save rule"
  defp rule_form_submit_label(_mode), do: "Create rule"

  defp channel_form_title(:edit), do: "Edit channel"
  defp channel_form_title(_mode), do: "Create channel"

  defp channel_form_submit_label(:edit), do: "Save channel"
  defp channel_form_submit_label(_mode), do: "Create channel"

  defp webhook_url_placeholder(:edit), do: "Leave blank to preserve stored webhook URL"
  defp webhook_url_placeholder(_mode), do: "https://hooks.example.com/alerts"

  defp rule_count_label([]), do: "0 rules"
  defp rule_count_label([_rule]), do: "1 rule"
  defp rule_count_label(rules), do: "#{length(rules)} rules"

  defp channel_count_label([]), do: "0 channels"
  defp channel_count_label([_channel]), do: "1 channel"
  defp channel_count_label(channels), do: "#{length(channels)} channels"

  defp channel_endpoint_label(%{channel_type: "email", email_to: email_to}), do: email_to

  defp channel_endpoint_label(%{endpoint_scheme: scheme, endpoint_host: host} = channel)
       when is_binary(scheme) and is_binary(host) do
    scheme <> "://" <> host <> (channel.endpoint_path_prefix || "")
  end

  defp channel_endpoint_label(_channel), do: "not configured"

  defp channel_form_secret_status(%{webhook_signing_secret_key_version: key_version}),
    do: AlertChannelForm.secret_status_label(key_version)

  defp channel_form_secret_status(_channel), do: "not configured"

  defp pool_name_for(pool_lookup, pool_id),
    do: pool_lookup |> Map.fetch!(pool_id) |> Map.fetch!(:name)

  defp pool_slug_for(pool_lookup, pool_id),
    do: pool_lookup |> Map.fetch!(pool_id) |> Map.fetch!(:slug)

  defp threshold_summary(%AlertRule{rule_kind: "pool_low_usable_assignments"} = rule),
    do: "Minimum #{rule.min_usable_assignments || 1} usable assignments"

  defp threshold_summary(%AlertRule{rule_kind: "pool_all_assignments_in_state"} = rule),
    do: "All assignments #{AlertRuleForm.target_state_label(rule.target_state)}"

  defp threshold_summary(%AlertRule{rule_kind: "upstream_quota_threshold"} = rule),
    do:
      "#{AlertRuleForm.window_selector_label(rule.window_selector)} at #{AlertRuleForm.threshold_label(rule.threshold_used_percent)}"

  defp threshold_summary(%AlertRule{rule_kind: "upstream_auth_state"} = rule),
    do: "Assigned upstream #{AlertRuleForm.target_state_label(rule.target_state)}"

  defp threshold_summary(_rule), do: "No usable assignments"

  attr :incident, :map, required: true
  attr :prefix, :string, required: true

  def impacted_pool_list(assigns) do
    ~H"""
    <div
      id={"#{@prefix}-#{@incident.id}-impacted-pools"}
      data-role="incident-impacted-pools"
      class="grid gap-1"
    >
      <p
        :if={@incident.impacted_pools == []}
        id={"#{@prefix}-#{@incident.id}-no-visible-impacted-pools"}
        data-role="incident-no-visible-impacted-pools"
        class="text-xs text-base-content/55"
      >
        No visible impacted Pools
      </p>
      <ul :if={@incident.impacted_pools != []} class="grid gap-1">
        <li
          :for={pool <- @incident.impacted_pools}
          id={"#{@prefix}-#{@incident.id}-impacted-pool-#{pool.id}"}
          data-role="incident-impacted-pool"
          class="grid min-w-0 gap-0.5"
        >
          <span data-role="incident-impacted-pool-name" class="truncate font-medium text-base-content">
            {pool.name}
          </span>
          <span
            data-role="incident-impacted-pool-slug"
            class="truncate font-mono text-xs text-base-content/45"
          >
            {pool.slug}
          </span>
        </li>
      </ul>
      <p
        :if={@incident.hidden_impacted_pool_count > 0}
        id={"#{@prefix}-#{@incident.id}-hidden-pool-count"}
        data-role="incident-hidden-pool-count"
        class="text-xs font-medium text-warning"
      >
        {hidden_pool_count_label(@incident.hidden_impacted_pool_count)}
      </p>
    </div>
    """
  end

  attr :incident, :map, required: true
  attr :prefix, :string, required: true

  def incident_action_controls(assigns) do
    ~H"""
    <div id={"#{@prefix}-#{@incident.id}-actions"} class="flex flex-wrap justify-end gap-2">
      <AdminComponents.action_button
        :if={@incident.state == AlertIncident.open_state()}
        id={incident_action_id(@prefix, @incident.id, "acknowledge")}
        icon="hero-hand-raised"
        label="Acknowledge"
        phx-click="acknowledge_incident"
        phx-value-id={@incident.id}
      />
      <AdminComponents.action_button
        :if={@incident.state != AlertIncident.resolved_state()}
        id={incident_action_id(@prefix, @incident.id, "resolve")}
        icon="hero-check-circle"
        label="Resolve"
        phx-click="resolve_incident"
        phx-value-id={@incident.id}
        variant={:primary}
      />
      <span
        :if={@incident.state == AlertIncident.resolved_state()}
        id={"#{@prefix}-#{@incident.id}-actions-resolved"}
        class="text-xs font-medium text-base-content/50"
      >
        No pending actions
      </span>
    </div>
    """
  end

  attr :incident, :map, required: true
  attr :prefix, :string, required: true

  def incident_delivery_summary(assigns) do
    ~H"""
    <div class="grid gap-2">
      <p id={"#{@prefix}-#{@incident.id}-delivery-label"} data-role="incident-delivery-label">
        {@incident.delivery_summary.label}
      </p>
      <ul
        :if={@incident.delivery_summary.attempts != []}
        id={"#{@prefix}-#{@incident.id}-delivery-attempts"}
        data-role="incident-delivery-attempts"
        class="grid gap-2"
      >
        <li
          :for={attempt <- @incident.delivery_summary.attempts}
          id={"#{@prefix}-#{@incident.id}-delivery-attempt-#{attempt.id}"}
          data-role="incident-delivery-attempt"
          class="rounded-box border border-base-300 bg-base-200/60 p-2"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span
              data-role="incident-delivery-attempt-channel"
              class="font-medium text-base-content/80"
            >
              {attempt.channel_label}
            </span>
            <span
              data-role="incident-delivery-attempt-status"
              class={AdminBadges.status_chip_class(attempt.status)}
            >
              {attempt.status_label}
            </span>
          </div>
          <p
            id={"#{@prefix}-#{@incident.id}-delivery-attempt-#{attempt.id}-meta"}
            data-role="incident-delivery-attempt-meta"
            class="mt-1 font-mono text-[0.68rem] text-base-content/55"
          >
            Attempt {attempt.attempt_number}/{attempt.max_attempts} · {format_datetime(
              attempt.attempted_at || attempt.completed_at
            )}
          </p>
          <dl
            :if={attempt.details != []}
            id={"#{@prefix}-#{@incident.id}-delivery-attempt-#{attempt.id}-details"}
            data-role="incident-delivery-attempt-details"
            class="mt-2 grid gap-1 text-[0.68rem]"
          >
            <div :for={detail <- attempt.details} class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
              <dt class="text-base-content/45">{detail.label}</dt>
              <dd class="min-w-0 break-words font-mono text-base-content/65">{detail.value}</dd>
            </div>
          </dl>
        </li>
      </ul>
    </div>
    """
  end

  def severity_chip_class("critical"), do: AdminBadges.status_chip_class("open")
  def severity_chip_class("warning"), do: AdminBadges.status_chip_class("paused")
  def severity_chip_class("info"), do: AdminBadges.status_chip_class("pending")
  def severity_chip_class(_severity), do: AdminBadges.status_chip_class(nil)

  def format_datetime(nil), do: "not recorded"

  def format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp hidden_pool_count_label(1), do: "1 hidden impacted Pool"
  defp hidden_pool_count_label(count), do: "#{count} hidden impacted Pools"

  defp incident_action_id("alert-incident-card", incident_id, action),
    do: "alert-incident-card-#{action}-#{incident_id}"

  defp incident_action_id(_prefix, incident_id, action),
    do: "alert-incident-#{action}-#{incident_id}"
end
