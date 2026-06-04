defmodule CodexPoolerWeb.Admin.JobWorkerCards do
  @moduledoc false

  use CodexPoolerWeb, :html

  import CodexPoolerWeb.Admin.JobsPresentation

  alias CodexPoolerWeb.Admin.AvatarComponents

  attr :card, :map, required: true
  attr :datetime_preferences, :map, required: true

  def job_worker_card(assigns) do
    ~H"""
    <article
      id={"job-worker-card-#{@card.id}"}
      class="grid min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100 shadow-sm"
    >
      <.job_worker_card_header card={@card} />

      <.worker_activity_strip card={@card} />
      <.job_failure_dialog
        :for={marker <- @card.visible_failure_markers}
        marker={marker}
        datetime_preferences={@datetime_preferences}
      />
      <.worker_latest_failure
        :if={@card.latest_failure}
        card={@card}
        datetime_preferences={@datetime_preferences}
      />
      <.worker_schedule_facts card={@card} datetime_preferences={@datetime_preferences} />
    </article>
    """
  end

  defp job_worker_card_header(assigns) do
    ~H"""
    <header class="grid min-w-0 gap-3 px-4 pb-3 pt-4 sm:grid-cols-[minmax(0,1fr)_auto]">
      <div class="flex min-w-0 items-start gap-2.5">
        <span class="grid size-9 shrink-0 place-items-center rounded-box border border-base-300 bg-base-200 text-base-content/70">
          <.icon name={@card.icon} class="size-4" />
        </span>
        <div class="grid min-w-0 gap-0.5">
          <h2 class="truncate text-base font-semibold text-base-content">{@card.title}</h2>
          <p class="text-xs leading-5 text-base-content/60">{@card.description}</p>
        </div>
      </div>

      <div class="flex flex-wrap items-start gap-2 sm:justify-end">
        <span
          data-role="state-icon"
          title={@card.state_label}
          aria-label={"State: #{@card.state_label}"}
          class={[
            "inline-flex shrink-0 items-center gap-2 rounded-box border px-2.5 py-1 text-xs font-semibold",
            job_state_badge_class(@card.state)
          ]}
        >
          <span
            :if={@card.live_state}
            data-role="worker-live-dot"
            class="size-2 rounded-full bg-current motion-safe:animate-pulse"
          />
          <.icon :if={!@card.live_state} name={job_state_icon(@card.state)} class="size-4" />
          <span>{@card.state_label}</span>
        </span>
      </div>
    </header>
    """
  end

  defp worker_activity_strip(assigns) do
    ~H"""
    <section
      :if={@card.active_markers != [] or @card.failure_markers != []}
      data-role="worker-activity-strip"
      class="border-t border-base-300 bg-base-200/35 px-5 py-3"
    >
      <div class="flex min-w-0 flex-wrap items-center justify-between gap-3">
        <span class="text-xs font-medium text-base-content/60">{@card.activity_label}</span>

        <div class="flex min-w-0 flex-wrap items-center gap-1.5">
          <span
            :for={marker <- @card.visible_active_markers}
            id={"job-activity-#{marker.id}"}
            data-role="active-worker-marker"
            aria-label={marker.title}
            title={marker.title}
            data-has-avatar={marker.avatar_email && "true"}
            class="relative grid size-8 shrink-0 place-items-center overflow-hidden rounded-full border border-info/50 bg-info/10 text-[0.6875rem] font-semibold leading-none text-info shadow-sm"
          >
            <AvatarComponents.gravatar
              :if={marker.avatar_email}
              id={"job-activity-avatar-#{marker.id}"}
              email={marker.avatar_email}
              label={marker.target_label}
              size={64}
              class="pointer-events-none"
              image_class="size-8 rounded-full ring-0"
            />
            <span :if={!marker.avatar_email} data-role="target-initial">{marker.glyph}</span>
            <span
              data-role="target-live-indicator"
              class="absolute -bottom-0.5 -right-0.5 size-2.5 rounded-full bg-info ring-2 ring-base-100 motion-safe:animate-pulse"
            />
          </span>
          <span
            :if={@card.active_marker_overflow_count > 0}
            data-role="active-worker-overflow"
            title={"#{@card.active_marker_overflow_count} more running targets"}
            class="grid size-8 shrink-0 place-items-center rounded-full border border-info/30 bg-info/5 text-[0.6875rem] font-semibold text-info"
          >
            +{@card.active_marker_overflow_count}
          </span>

          <button
            :for={marker <- @card.visible_failure_markers}
            id={"job-failure-#{marker.id}"}
            type="button"
            data-role="failed-worker-marker"
            aria-label={marker.title}
            title={marker.title}
            data-has-avatar={marker.avatar_email && "true"}
            class="relative grid size-8 shrink-0 place-items-center overflow-hidden rounded-full border border-error/60 bg-error/10 text-[0.6875rem] font-semibold leading-none text-error shadow-sm transition-colors hover:bg-error/15 focus:outline-none focus:ring-2 focus:ring-error/40"
            onclick={"document.getElementById('job-failure-dialog-#{marker.id}').showModal()"}
          >
            <AvatarComponents.gravatar
              :if={marker.avatar_email}
              id={"job-failure-avatar-#{marker.id}"}
              email={marker.avatar_email}
              label={marker.target_label}
              size={64}
              class="pointer-events-none"
              image_class="size-8 rounded-full ring-0"
            />
            <span :if={!marker.avatar_email} data-role="target-initial">{marker.glyph}</span>
            <span class="absolute -bottom-0.5 -right-0.5 grid size-3.5 place-items-center rounded-full bg-error text-error-content ring-2 ring-base-100">
              <.icon name="hero-exclamation-triangle" class="size-2.5" />
            </span>
          </button>
          <span
            :if={@card.failure_marker_overflow_count > 0}
            data-role="failed-worker-overflow"
            title={"#{@card.failure_marker_overflow_count} more failed targets"}
            class="grid size-8 shrink-0 place-items-center rounded-full border border-error/40 bg-error/5 text-[0.6875rem] font-semibold text-error"
          >
            +{@card.failure_marker_overflow_count}
          </span>
        </div>
      </div>
    </section>
    """
  end

  attr :card, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp worker_latest_failure(assigns) do
    ~H"""
    <section
      data-role="worker-latest-failure"
      class="border-t border-error/20 bg-error/5 px-4 py-3 text-sm"
    >
      <div class="grid gap-3">
        <div class="min-w-0">
          <p class="text-xs font-semibold uppercase text-error">Latest failure</p>
          <p class="mt-1 truncate font-semibold text-base-content">
            {@card.latest_failure.target_label}
          </p>
          <p data-role="latest-failure-message" class="mt-1 leading-6 text-base-content/70">
            {@card.latest_failure.message}
          </p>
        </div>
        <dl
          data-role="latest-failure-meta"
          class="grid grid-cols-2 gap-3 text-xs text-base-content/60 sm:max-w-sm"
        >
          <div>
            <dt>When</dt>
            <dd class="font-semibold tabular-nums text-base-content">
              {format_job_timestamp(@card.latest_failure.failed_at, @datetime_preferences)}
            </dd>
          </div>
          <div>
            <dt>Attempts</dt>
            <dd class="font-semibold tabular-nums text-base-content">
              {@card.latest_failure.attempts}
            </dd>
          </div>
        </dl>
      </div>
    </section>
    """
  end

  attr :marker, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp job_failure_dialog(assigns) do
    ~H"""
    <dialog id={"job-failure-dialog-#{@marker.id}"} data-role="failed-worker-dialog" class="modal">
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <header class="border-b border-base-300 px-5 py-4">
          <p class="text-xs font-semibold uppercase text-error">Job failure</p>
          <h3 class="mt-1 text-lg font-semibold text-base-content">
            {@marker.target_label}
          </h3>
          <p class="mt-1 text-xs text-base-content/60">{@marker.worker_label}</p>
        </header>
        <div class="grid gap-3 px-5 py-4 text-sm">
          <p class="font-semibold text-error">{@marker.failure.title}</p>
          <p data-role="failure-message" class="leading-relaxed text-base-content/70">
            {@marker.failure.message}
          </p>
          <dl class="grid gap-2 text-xs text-base-content/60 sm:grid-cols-2">
            <div>
              <dt>Last failure</dt>
              <dd class="tabular-nums text-base-content">
                {format_job_timestamp(@marker.failed_at, @datetime_preferences)}
              </dd>
            </div>
            <div>
              <dt>Attempts</dt>
              <dd class="tabular-nums text-base-content">{@marker.attempts}</dd>
            </div>
          </dl>
        </div>
        <form method="dialog" class="modal-action mt-0 border-t border-base-300 px-5 py-4">
          <button class="btn btn-sm">Close</button>
        </form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button>close</button>
      </form>
    </dialog>
    """
  end

  attr :card, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp worker_schedule_facts(assigns) do
    ~H"""
    <section
      data-role="worker-schedule-facts"
      data-density="compact"
      class="grid gap-3 border-t border-base-300 px-4 py-3 sm:grid-cols-[minmax(7rem,0.65fr)_minmax(0,1fr)] sm:items-start"
    >
      <div data-role="next-run-group" class="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-0.5">
        <span class="text-xs text-base-content/50">Next run</span>
        <strong
          data-role="next-run"
          class="text-base font-semibold leading-tight text-base-content"
          title={@card.next_run_title}
        >
          {@card.next_run}
        </strong>
        <span
          :if={@card.cadence_label != @card.next_run}
          class="text-xs text-base-content/50"
          title={@card.cadence_label}
        >
          {@card.cadence_label}
        </span>
      </div>

      <dl class="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
        <div data-role="last-run" class="grid min-w-0 gap-0.5">
          <dt class="text-base-content/50">Last run</dt>
          <dd class="font-semibold tabular-nums text-base-content">
            {format_job_timestamp(@card.last_seen_at, @datetime_preferences)}
          </dd>
        </div>
        <div data-role="attempts" class="grid min-w-0 gap-0.5">
          <dt class="text-base-content/50">Attempts</dt>
          <dd class="font-semibold tabular-nums text-base-content">{@card.attempts}</dd>
        </div>
      </dl>
    </section>
    """
  end
end
