defmodule CodexPoolerWeb.Admin.StatsPresentation do
  @moduledoc """
  Presentation components and chart models for the admin stats dashboard.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  @default_quota_state_presentation %{tone: :neutral, label: nil}
  @quota_state_presentations %{
    available: %{tone: :success, label: "Available"},
    partial: %{tone: :warning, label: "Partial"},
    weekly_only_evidence: %{tone: :warning, label: "Weekly evidence only"},
    missing_evidence: %{tone: :error, label: "Missing evidence"},
    exhausted: %{tone: :error, label: "Exhausted"},
    unknown: %{tone: :neutral, label: "Unknown"},
    empty: %{tone: :neutral, label: "No upstream accounts"}
  }

  attr :dashboard, :map, required: true

  def dashboard_context(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3 rounded-box border border-base-300 bg-base-100 p-4 shadow-sm">
      <div class="grid gap-1">
        <p id="stats-selected-scope" class="text-sm font-semibold text-base-content">
          {selected_scope_label(@dashboard)}
        </p>
        <p id="stats-selected-window" class="text-xs text-base-content/60">
          {format_datetime(@dashboard.filters.started_at)} to {format_datetime(
            @dashboard.filters.ended_at
          )} UTC
        </p>
      </div>
      <span id="stats-usage-source" class={AdminBadges.metadata_chip_class(:primary)}>
        {usage_source_label(@dashboard.sources.usage_source)}
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :dashboard, :map, required: true

  def kpi_strip(assigns) do
    ~H"""
    <AdminComponents.metric_strip id={@id}>
      <AdminComponents.metric_card
        id="stats-kpi-requests"
        icon="hero-arrow-path-rounded-square"
        label="Requests"
        value={format_integer(@dashboard.kpis.requests.value)}
        description={request_summary(@dashboard.kpis.requests)}
        tone={request_tone(@dashboard.kpis.requests)}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-success-rate"
        icon="hero-check-circle"
        label="Success rate"
        value={format_percent(@dashboard.kpis.success_rate.value)}
        description="Completed"
        tone={success_rate_tone(@dashboard.kpis.success_rate.value)}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-tokens"
        icon="hero-cpu-chip"
        label="Tokens"
        value={format_integer(@dashboard.kpis.tokens.total_tokens)}
        description={token_summary(@dashboard.kpis.tokens)}
        tone={:primary}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-tokens-per-sec"
        icon="hero-bolt"
        label="Throughput"
        value={format_float(@dashboard.kpis.tokens_per_second.value)}
        description="Tokens per second"
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-cost"
        icon="hero-currency-dollar"
        label="Cost"
        value={format_cost(@dashboard.kpis.estimated_cost)}
        description={cost_status_label(@dashboard.kpis.estimated_cost.status)}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-avg-latency"
        icon="hero-clock"
        label="Latency"
        value={format_latency(@dashboard.kpis.average_latency_ms.value)}
        description="Mean response time"
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-active-sessions"
        icon="hero-computer-desktop"
        label="Active sessions"
        value={format_integer(@dashboard.kpis.active_sessions.value)}
        description={turn_summary(@dashboard.kpis.turns)}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-quota-health"
        icon="hero-shield-check"
        label="Quota"
        value={quota_state_label(@dashboard.kpis.quota_health.state)}
        description={quota_summary(@dashboard.kpis.quota_health)}
        tone={quota_tone(@dashboard.kpis.quota_health.state)}
        compact_mobile
      />
    </AdminComponents.metric_strip>
    """
  end

  attr :rows, :list, required: true

  def top_api_keys_table(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="stats-api-key-surface"
      title="Top API keys"
      description="Highest usage in this range."
      count={"#{length(@rows)} rows"}
    >
      <div class="overflow-x-auto">
        <table id="stats-api-key-table" class="table table-zebra table-sm">
          <thead>
            <tr>
              <th>API key</th>
              <th class="text-right">Requests</th>
              <th class="text-right">Tokens</th>
              <th class="text-right">Cost</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@rows == []} id="stats-api-key-empty-row">
              <td colspan="4" class="text-center text-sm text-base-content/60">
                No settled API-key usage for this period.
              </td>
            </tr>
            <tr :for={{row, index} <- Enum.with_index(@rows)} id={"stats-api-key-row-#{index}"}>
              <td class="min-w-44 font-semibold">
                {row.display_name || "API key not recorded"}
              </td>
              <td class="text-right font-mono tabular-nums">
                {format_integer(row.requests)}
              </td>
              <td class="text-right font-mono tabular-nums">
                {format_integer(row.total_tokens)}
              </td>
              <td class="text-right font-mono tabular-nums">
                {format_micros(row.estimated_cost_micros)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </AdminComponents.admin_surface>
    """
  end

  attr :rows, :list, required: true

  def upstreams_table(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="stats-upstream-surface"
      title="Upstream usage"
      description="Account state and usage in this range."
      count={"#{length(@rows)} rows"}
    >
      <div class="overflow-x-auto">
        <table id="stats-upstream-table" class="table table-zebra table-sm">
          <thead>
            <tr>
              <th>Upstream</th>
              <th>Status</th>
              <th>Quota</th>
              <th class="text-right">Requests</th>
              <th class="text-right">Tokens</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@rows == []} id="stats-upstream-empty-row">
              <td colspan="5" class="text-center text-sm text-base-content/60">
                No upstream assignments in this scope.
              </td>
            </tr>
            <tr :for={{row, index} <- Enum.with_index(@rows)} id={"stats-upstream-row-#{index}"}>
              <td class="min-w-56">
                <div class="grid gap-1">
                  <span class="font-semibold">
                    {row.assignment_label || row.upstream_label || "upstream account"}
                  </span>
                </div>
              </td>
              <td>
                <span class={AdminBadges.status_chip_class(row.status)}>
                  {row.status || "unknown"}
                </span>
              </td>
              <td>
                <span class={AdminBadges.status_chip_class(row.quota_state)}>
                  {quota_state_label(row.quota_state)}
                </span>
              </td>
              <td class="text-right font-mono tabular-nums">
                {format_integer(row.requests)}
              </td>
              <td class="text-right font-mono tabular-nums">
                {format_integer(row.total_tokens)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </AdminComponents.admin_surface>
    """
  end

  attr :accounts, :list, required: true

  def quota_table(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="stats-quota-table"
      title="Quota evidence"
      description="Latest quota state by upstream account."
      count={"#{length(@accounts)} rows"}
    >
      <div class="overflow-x-auto">
        <table class="table table-zebra table-sm">
          <thead>
            <tr>
              <th>Account</th>
              <th>State</th>
              <th>Primary 5h</th>
              <th>Secondary</th>
              <th class="text-right">Evidence</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@accounts == []} id="stats-quota-empty-row">
              <td colspan="5" class="text-center text-sm text-base-content/60">
                No quota evidence in this scope.
              </td>
            </tr>
            <tr :for={{account, index} <- Enum.with_index(@accounts)} id={"stats-quota-row-#{index}"}>
              <td class="min-w-52">
                <div class="grid gap-1">
                  <span class="font-semibold">
                    {account.assignment_label || account.upstream_label || "upstream account"}
                  </span>
                  <span class="text-xs text-base-content/60">
                    {quota_plan_label(account)}
                  </span>
                </div>
              </td>
              <td>
                <span class={AdminBadges.status_chip_class(account.state)}>
                  {quota_state_label(account.state)}
                </span>
              </td>
              <td class="min-w-40 text-sm">{quota_window_label(account, :primary_5h)}</td>
              <td class="min-w-40 text-sm">{quota_window_label(account, :secondary)}</td>
              <td class="text-right font-mono tabular-nums">
                {format_integer(account.evidence_count)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </AdminComponents.admin_surface>
    """
  end

  defp selected_scope_label(%{selected_pool: %{name: name, slug: slug}}), do: "#{name} (#{slug})"
  defp selected_scope_label(_dashboard), do: "All visible Pools"

  defp request_summary(%{succeeded: succeeded, failed: failed}),
    do: "#{format_integer(succeeded)} succeeded · #{format_integer(failed)} failed"

  defp token_summary(tokens),
    do:
      "#{format_integer(tokens.input_tokens)} input · #{format_integer(tokens.cached_input_tokens)} cached · #{format_integer(tokens.output_tokens)} output"

  defp turn_summary(turns),
    do: "#{format_integer(turns.value)} turns · #{format_integer(turns.in_progress)} in progress"

  defp quota_summary(%{total: 0}), do: "No upstream accounts"

  defp quota_summary(%{state: :weekly_only_evidence, weekly_only_evidence: count}),
    do: "#{format_integer(count)} account with weekly evidence only"

  defp quota_summary(quota),
    do:
      "#{format_integer(quota.available)} usable · #{format_integer(quota.missing_evidence)} missing quota"

  defp request_tone(%{failed: failed}) when failed > 0, do: :warning
  defp request_tone(_requests), do: :neutral

  defp success_rate_tone(nil), do: :neutral
  defp success_rate_tone(value) when value >= 95.0, do: :success
  defp success_rate_tone(value) when value >= 50.0, do: :warning
  defp success_rate_tone(_value), do: :error

  defp quota_tone(state), do: quota_state_presentation(state).tone

  defp quota_state_label(state) do
    case quota_state_presentation(state).label do
      nil -> humanize(state)
      label -> label
    end
  end

  defp quota_state_presentation(state),
    do: Map.get(@quota_state_presentations, state, @default_quota_state_presentation)

  defp quota_plan_label(%{plan_family: plan_family}) when is_binary(plan_family),
    do: humanize(plan_family)

  defp quota_plan_label(_account), do: "plan not recorded"

  defp quota_window_label(%{state: :weekly_only_evidence}, :primary_5h),
    do: "5h quota not reported"

  defp quota_window_label(account, key) do
    case Map.get(account, key) do
      nil ->
        "not recorded"

      %{used_percent: used_percent, reset_at: reset_at, routing_usable?: routing_usable?} ->
        [format_used_percent(used_percent), reset_label(reset_at), usable_label(routing_usable?)]
        |> Enum.reject(&blank?/1)
        |> Enum.join(" · ")
    end
  end

  defp usage_source_label(:raw_ledger_fallback), do: "live usage"
  defp usage_source_label(:raw_ledger_with_rollup_context), do: "live usage + daily totals"
  defp usage_source_label(source), do: humanize(source)

  defp format_cost(%{usd: %Decimal{} = usd}), do: "$#{Decimal.to_string(usd, :normal)}"
  defp format_cost(%{status: "unpriced"}), do: "unpriced"
  defp format_cost(%{status: "unavailable"}), do: "unavailable"
  defp format_cost(%{status: status}), do: status || "unavailable"

  defp cost_status_label("estimated"), do: "Settled usage estimate"
  defp cost_status_label("unpriced"), do: "No price match"
  defp cost_status_label("unavailable"), do: "No usage"
  defp cost_status_label(status), do: humanize(status)

  defp format_micros(nil), do: "unavailable"
  defp format_micros(0), do: "unpriced"

  defp format_micros(micros) when is_integer(micros) do
    usd = micros |> Decimal.new() |> Decimal.div(Decimal.new(1_000_000)) |> Decimal.round(6)
    "$#{Decimal.to_string(usd, :normal)}"
  end

  defp format_percent(nil), do: "not available"
  defp format_percent(value), do: "#{format_float(value)}%"

  defp format_used_percent(nil), do: "usage not recorded"
  defp format_used_percent(value), do: "#{format_float(value)}% used"

  defp format_latency(nil), do: "not available"
  defp format_latency(value), do: "#{format_integer(value)} ms"

  defp format_float(nil), do: "not available"
  defp format_float(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_float(value) when is_integer(value), do: Integer.to_string(value)

  defp format_datetime(nil), do: "not recorded"

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  defp format_integer(nil), do: "0"
  defp format_integer(value) when is_integer(value), do: Integer.to_string(value)
  defp format_integer(value) when is_float(value), do: format_float(value)

  defp reset_label(nil), do: "reset not recorded"
  defp reset_label(%DateTime{} = reset_at), do: "resets #{format_datetime(reset_at)}"

  defp usable_label(true), do: "routing usable"
  defp usable_label(false), do: "display only"

  defp humanize(nil), do: nil

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace(["_", "."], " ")
    |> String.trim()
    |> String.capitalize()
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""
end
