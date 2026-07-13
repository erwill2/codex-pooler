defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.ReconciliationStatus do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :id_prefix, :string, required: true
  attr :identity_observability, :map, required: true
  attr :reauth_required?, :boolean, required: true
  attr :lifecycle_warning, :map, default: nil
  attr :recovery_href, :string, required: true
  attr :recovery_label, :string, required: true

  def reconciliation_status(assigns) do
    assigns =
      assign(
        assigns,
        :state,
        state(assigns.identity_observability, assigns.reauth_required?, assigns.lifecycle_warning)
      )

    ~H"""
    <section
      :if={@state.visible?}
      id={"#{@id_prefix}-reconciliation-status"}
      data-role="upstream-reconciliation-status"
      data-reconciliation-status={@state.reconciliation_status}
      class={[
        "grid gap-2 rounded-box border p-3 text-sm",
        tone_class(@state.tone)
      ]}
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div class="flex min-w-0 items-start gap-2">
          <.icon name={tone_icon(@state.tone)} class={tone_icon_class(@state.tone)} />
          <div class="grid min-w-0 gap-1">
            <h3 id={"#{@id_prefix}-reconciliation-title"} class={tone_title_class(@state.tone)}>
              {@state.title}
            </h3>
            <p id={"#{@id_prefix}-reconciliation-summary"} class="text-base-content/80">
              {@state.summary}
            </p>
          </div>
        </div>
        <span
          :if={@state.attempt_age}
          id={"#{@id_prefix}-reconciliation-attempt-age"}
          class="shrink-0 text-xs text-base-content/65"
        >
          latest attempt {@state.attempt_age}
        </span>
      </div>
      <p
        :if={@state.reason}
        id={"#{@id_prefix}-reconciliation-reason"}
        class="text-xs text-base-content/70"
      >
        {@state.reason}
      </p>
      <dl class="grid gap-1 text-xs text-base-content/70 sm:grid-cols-2">
        <div>
          <dt class="sr-only">Last successful refresh</dt>
          <dd id={"#{@id_prefix}-last-successful-refresh"}>
            {age_label("Last successful quota refresh", @state.last_successful_refresh_age)}
          </dd>
        </div>
        <div>
          <dt class="sr-only">Quota evidence age</dt>
          <dd id={"#{@id_prefix}-quota-evidence-age"}>
            {age_label("Quota evidence", @state.quota_evidence_age)}
          </dd>
        </div>
      </dl>
      <.link
        :if={@state.recovery_needed?}
        id={"#{@id_prefix}-reconciliation-recovery"}
        href={@recovery_href}
        class="link link-primary w-fit text-xs font-semibold"
      >
        {@recovery_label}
      </.link>
    </section>
    """
  end

  defp state(observability, reauth_required?, lifecycle_warning) do
    reconciliation = Map.get(observability, :reconciliation, %{})
    reconciliation_status = Map.get(reconciliation, :status)
    reconciliation_reason = Map.get(reconciliation, :message) || Map.get(reconciliation, :code)

    {tone, title, summary, reason, recovery_needed?} =
      cond do
        is_map(lifecycle_warning) ->
          {:error, Map.fetch!(lifecycle_warning, :title), Map.fetch!(lifecycle_warning, :body),
           Map.get(lifecycle_warning, :reason) || reconciliation_reason, true}

        reauth_required? ->
          {:error, "Reauthentication required",
           "Credentials need recovery before this account can route.", reconciliation_reason,
           true}

        reconciliation_status in ["failed", "partial", "blocked"] ->
          {:error, "Quota reconciliation needs attention",
           "The latest reconciliation did not complete successfully.", reconciliation_reason,
           true}

        true ->
          {:neutral, nil, nil, nil, false}
      end

    %{
      visible?: tone != :neutral,
      tone: tone,
      title: title,
      summary: summary,
      reason: reason,
      reconciliation_status: reconciliation_status || "unavailable",
      attempt_age: Map.get(reconciliation, :attempt_age),
      last_successful_refresh_age: Map.get(observability, :last_successful_quota_refresh_age),
      quota_evidence_age: Map.get(observability, :quota_evidence_age),
      recovery_needed?: recovery_needed?
    }
  end

  defp age_label(label, age) when is_binary(age) and age != "", do: "#{label} #{age}"
  defp age_label(label, _age), do: "#{label} not reported"

  defp tone_class(:error), do: "border-error/30 bg-error/10"
  defp tone_class(_tone), do: "border-base-300 bg-base-200/30"

  defp tone_icon(:error), do: "hero-exclamation-triangle"
  defp tone_icon(_tone), do: "hero-information-circle"

  defp tone_icon_class(:error), do: "mt-0.5 size-5 shrink-0 text-error"
  defp tone_icon_class(_tone), do: "mt-0.5 size-5 shrink-0 text-base-content/60"

  defp tone_title_class(:error), do: "font-semibold text-error"
  defp tone_title_class(_tone), do: "font-semibold text-base-content"
end
