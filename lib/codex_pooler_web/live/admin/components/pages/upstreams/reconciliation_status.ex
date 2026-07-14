defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.ReconciliationStatus do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :id_prefix, :string, required: true
  attr :identity_observability, :map, required: true
  attr :reauth_required?, :boolean, required: true
  attr :lifecycle_warning, :map, default: nil

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
        "flex items-start gap-2 rounded-box border p-3 text-sm",
        tone_class(@state.tone)
      ]}
    >
      <.icon name={tone_icon(@state.tone)} class={tone_icon_class(@state.tone)} />
      <div class="grid min-w-0 flex-1 gap-1">
        <div class="flex min-w-0 flex-wrap items-baseline justify-between gap-x-3">
          <h3 id={"#{@id_prefix}-reconciliation-title"} class={tone_title_class(@state.tone)}>
            {@state.title}
          </h3>
          <span
            :if={@state.attempt_age}
            id={"#{@id_prefix}-reconciliation-attempt-age"}
            class="text-xs text-base-content/65"
          >
            latest attempt {@state.attempt_age}
          </span>
        </div>
        <p id={"#{@id_prefix}-reconciliation-summary"} class="text-base-content/80">
          {@state.summary}
        </p>
        <p
          :if={@state.reason}
          id={"#{@id_prefix}-reconciliation-reason"}
          class="text-xs text-base-content/70"
        >
          {@state.reason}
        </p>
        <dl class="flex flex-wrap gap-x-4 gap-y-0.5 text-xs text-base-content/60">
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
      </div>
    </section>
    """
  end

  defp state(observability, reauth_required?, lifecycle_warning) do
    reconciliation = Map.get(observability, :reconciliation, %{})
    reconciliation_status = Map.get(reconciliation, :status)
    reconciliation_reason = Map.get(reconciliation, :message) || Map.get(reconciliation, :code)

    {tone, title, summary, reason} =
      cond do
        is_map(lifecycle_warning) ->
          {:error, Map.fetch!(lifecycle_warning, :title), Map.fetch!(lifecycle_warning, :body),
           Map.get(lifecycle_warning, :reason) || reconciliation_reason}

        reauth_required? ->
          {:error, "Reauthentication required",
           "Credentials need recovery before this account can route.", reconciliation_reason}

        reconciliation_status in ["failed", "partial", "blocked"] ->
          {:error, "Quota reconciliation needs attention",
           reconciliation_reason || "The latest reconciliation did not complete successfully.",
           nil}

        true ->
          {:neutral, nil, nil, nil}
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
      quota_evidence_age: Map.get(observability, :quota_evidence_age)
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
