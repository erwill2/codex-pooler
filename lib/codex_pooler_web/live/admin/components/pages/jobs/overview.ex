defmodule CodexPoolerWeb.Admin.JobOverview do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  @action_buckets [
    %{
      key: :active_failure,
      suffix: "active-failure",
      label: "Active failures",
      icon: "hero-x-circle",
      tone: :error,
      description: "Discarded or failed jobs"
    },
    %{
      key: :stuck_executing,
      suffix: "stuck-executing",
      label: "Stuck executing",
      icon: "hero-clock",
      tone: :warning,
      description: "Running past policy"
    },
    %{
      key: :retry_pressure,
      suffix: "retry-pressure",
      label: "Retry pressure",
      icon: "hero-arrow-path",
      tone: :warning,
      description: "Retryable failures"
    },
    %{
      key: :backlog_pressure,
      suffix: "backlog-pressure",
      label: "Backlog pressure",
      icon: "hero-queue-list",
      tone: :warning,
      description: "Overdue queued work"
    }
  ]

  attr :overview, :map, required: true

  def jobs_overview(assigns) do
    assigns =
      assign(assigns, :action_buckets, @action_buckets)

    ~H"""
    <div class="grid min-w-0 gap-4">
      <AdminComponents.metric_strip id="admin-jobs-overview" compact_mobile={true}>
        <section
          id="admin-jobs-health-summary"
          class={[
            "col-span-full grid gap-3 rounded-box border border-base-300 bg-base-100 p-4 shadow-sm lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center",
            health_summary_tone_class(@overview.status)
          ]}
          aria-live="polite"
        >
          <div class="grid min-w-0 gap-1">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/55">
              System job health
            </p>
            <h2 class="text-lg font-semibold text-base-content">
              {overview_status_label(@overview)}
            </h2>
            <p class="max-w-3xl text-sm leading-6 text-base-content/70">
              {overview_status_description(@overview)}
            </p>
          </div>
          <dl class="grid min-w-0 grid-cols-2 gap-2 text-xs sm:grid-cols-3 lg:min-w-80">
            <div class="rounded-box border border-base-300 bg-base-200/55 px-3 py-2">
              <dt class="font-medium text-base-content/60">Actionable</dt>
              <dd class="font-mono text-lg font-semibold tabular-nums text-base-content">
                {@overview.actionable_count}
              </dd>
            </div>
            <div class="rounded-box border border-base-300 bg-base-200/55 px-3 py-2">
              <dt class="font-medium text-base-content/60">Total</dt>
              <dd class="font-mono text-lg font-semibold tabular-nums text-base-content">
                {@overview.total}
              </dd>
            </div>
            <div class="rounded-box border border-base-300 bg-base-200/55 px-3 py-2">
              <dt class="font-medium text-base-content/60">Completed</dt>
              <dd class="font-mono text-lg font-semibold tabular-nums text-base-content">
                {@overview.completed_context_count}
              </dd>
            </div>
          </dl>
        </section>

        <AdminComponents.metric_card
          :for={bucket <- @action_buckets}
          id={"admin-jobs-overview-#{bucket.suffix}"}
          icon={bucket.icon}
          label={bucket.label}
          value={overview_bucket_count(@overview, bucket.key)}
          description={bucket.description}
          tone={overview_bucket_tone(@overview, bucket)}
          compact_mobile={true}
        />
      </AdminComponents.metric_strip>
    </div>
    """
  end

  defp overview_status_label(%{status: :attention_required}), do: "Attention required"
  defp overview_status_label(%{status: :healthy}), do: "Healthy"
  defp overview_status_label(%{status: :empty}), do: "Empty"
  defp overview_status_label(_overview), do: "Unknown"

  defp overview_status_description(%{status: :attention_required, actionable_count: count}) do
    "#{pluralize_count(count, "actionable job", "actionable jobs")} need operator review before row-level exploration."
  end

  defp overview_status_description(%{status: :healthy, completed_context_count: completed_count}) do
    "No actionable jobs. #{pluralize_count(completed_count, "completed job", "completed jobs")} provide recent context only."
  end

  defp overview_status_description(%{status: :empty}) do
    "No actionable jobs. Background work has not produced visible job metadata yet."
  end

  defp overview_status_description(_overview), do: "Job health is not classified yet."

  defp health_summary_tone_class(:attention_required), do: "bg-warning/5"
  defp health_summary_tone_class(:healthy), do: "bg-success/5"
  defp health_summary_tone_class(:empty), do: "bg-base-100"
  defp health_summary_tone_class(_status), do: "bg-base-100"

  defp overview_bucket_count(overview, bucket) do
    overview
    |> Map.get(:buckets, %{})
    |> Map.get(bucket, %{count: 0})
    |> Map.get(:count, 0)
  end

  defp overview_bucket_tone(overview, bucket) do
    if overview_bucket_count(overview, bucket.key) > 0, do: bucket.tone, else: :neutral
  end

  defp pluralize_count(1, singular, _plural), do: "1 #{singular}"
  defp pluralize_count(count, _singular, plural), do: "#{count} #{plural}"
end
