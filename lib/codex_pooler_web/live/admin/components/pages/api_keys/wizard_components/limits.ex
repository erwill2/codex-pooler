defmodule CodexPoolerWeb.Admin.ApiKeyWizardComponents.Limits do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :form, :any, required: true
  attr :limit_fields, :list, required: true

  def api_key_limits_step(assigns) do
    ~H"""
    <section id="api-key-step-limits-panel" class="grid min-w-0 gap-5">
      <div class="grid gap-1">
        <h3 class="text-lg font-semibold text-base-content">Limits</h3>
        <p class="text-sm leading-6 text-base-content/65">
          Leave a field blank when no cap should be saved.
        </p>
      </div>

      <div class="rounded-box border border-base-300 bg-base-100 p-4">
        <h4 class="font-semibold text-base-content">Default policy</h4>
        <div
          id="api-key-default-limits-grid"
          class="mt-4 grid gap-4 md:grid-cols-[minmax(0,1.15fr)_repeat(2,minmax(0,1fr))]"
        >
          <.limit_input :for={field <- @limit_fields} form={@form} field={field} prefix="default" />
        </div>
      </div>

      <div class="rounded-box border border-base-300 bg-base-100 p-4">
        <h4 class="font-semibold text-base-content">Model-scoped override</h4>
        <p class="mt-1 text-sm text-base-content/60">
          Optional single model override. Additional rows can be added in a later policy pass.
        </p>
        <div class="mt-4 grid gap-4 md:grid-cols-2">
          <.input
            field={@form[:model_policy_model_identifier]}
            type="text"
            label="Model identifier"
            placeholder="gpt-5-codex"
          />
          <.limit_input :for={field <- @limit_fields} form={@form} field={field} prefix="model" />
        </div>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :field, :string, required: true
  attr :prefix, :string, required: true

  def limit_input(assigns) do
    assigns = assign(assigns, :field_atom, String.to_atom("#{assigns.prefix}_#{assigns.field}"))

    ~H"""
    <.input
      field={@form[@field_atom]}
      type="number"
      label={limit_field_label(@field)}
      min="1"
      step="1"
    />
    """
  end

  def limit_field_label("max_requests_per_minute"), do: "Requests per minute"
  def limit_field_label("max_tokens_per_day"), do: "Tokens per day"
  def limit_field_label("max_tokens_per_week"), do: "Tokens per week"
  def limit_field_label("max_input_tokens_per_request"), do: "Input tokens per request"
  def limit_field_label("max_output_tokens_per_request"), do: "Output tokens per request"
end
