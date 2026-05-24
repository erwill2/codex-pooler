defmodule CodexPoolerWeb.Admin.PoolListComponents do
  @moduledoc """
  Pool inventory, filter, action menu, delete dialog, and inspector shell components.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.PoolInspectorComponents
  alias CodexPoolerWeb.Admin.PoolsReadModel

  alias Phoenix.LiveView.JS

  @quota_chart_order [:primary_5h, :weekly]
  @quota_chart_colors [
    {"bg-success", "var(--color-success)"},
    {"bg-primary", "var(--color-primary)"},
    {"bg-info", "var(--color-info)"},
    {"bg-secondary", "var(--color-secondary)"}
  ]
  @quota_used_color {"bg-base-300", "var(--color-base-300)"}

  attr :deleting_pool, :any, default: nil
  attr :delete_form, Phoenix.HTML.Form, required: true
  attr :delete_form_version, :integer, required: true
  attr :pool_filter_form, Phoenix.HTML.Form, required: true
  attr :pools, :list, required: true
  attr :selected_pool_row, :any, default: nil
  attr :selected_pool_tab, :string, required: true
  attr :can_manage_pools?, :boolean, required: true

  def pool_inventory(assigns) do
    ~H"""
    <.pool_delete_dialog
      deleting_pool={@deleting_pool}
      delete_form={@delete_form}
      delete_form_version={@delete_form_version}
    />

    <div id="pool-details-drawer-root" class="drawer drawer-end">
      <input
        id="pool-details-drawer"
        type="checkbox"
        class="drawer-toggle"
        checked={@selected_pool_row != nil}
      />

      <div class="drawer-content min-w-0">
        <section
          id="pool-inventory-surface"
          class="grid min-w-0 gap-4 overflow-visible"
        >
          <.pool_filter_form form={@pool_filter_form} />

          <AdminComponents.empty_state
            :if={@pools == []}
            id="pool-empty-state"
            title="No Pools Found"
            description="Create the first Pool before connecting upstreams or issuing API keys."
            icon="hero-server-stack"
          >
            <:actions>
              <AdminComponents.action_button
                :if={@can_manage_pools?}
                id="pool-empty-create-action"
                icon="hero-plus"
                label="Create Pool"
                phx-click="open_create_pool"
                variant={:primary}
              />
            </:actions>
          </AdminComponents.empty_state>

          <.pool_grid
            :if={@pools != []}
            pools={@pools}
            selected_pool_row={@selected_pool_row}
            can_manage_pools?={@can_manage_pools?}
          />
        </section>
      </div>

      <div class="drawer-side z-[70]">
        <label
          for="pool-details-drawer"
          aria-label="close Pool details"
          class="drawer-overlay"
          phx-click="close_pool_inspector"
        >
        </label>
        <PoolInspectorComponents.pool_inspector
          :if={@selected_pool_row}
          pool_row={@selected_pool_row}
          selected_tab={@selected_pool_tab}
        />
      </div>
    </div>
    """
  end

  attr :deleting_pool, :any, default: nil
  attr :delete_form, Phoenix.HTML.Form, required: true
  attr :delete_form_version, :integer, required: true

  defp pool_delete_dialog(assigns) do
    ~H"""
    <dialog :if={@deleting_pool} id="pool-delete-dialog" class="modal" open>
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-error">Hard delete</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Delete archived Pool</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Hard deletion is available only for archived Pools and requires the exact slug confirmation.
          </p>
        </div>

        <.form
          id="pool-delete-form"
          for={@delete_form}
          phx-submit="confirm_delete_pool"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input field={@delete_form[:id]} type="hidden" />
          <div class="alert alert-warning items-start">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <div class="grid gap-1">
              <p class="font-semibold">This removes {@deleting_pool.name} permanently.</p>
              <p class="text-sm">
                Type <span class="break-all font-semibold">{@deleting_pool.slug}</span> to confirm.
              </p>
            </div>
          </div>
          <.input
            field={@delete_form[:confirmation_slug]}
            id={"pool_delete_confirmation_slug_#{@delete_form_version}"}
            type="text"
            label="Confirm slug"
            placeholder={@deleting_pool.slug}
            required
          />
          <div class="modal-action mt-0">
            <AdminComponents.action_button
              id="pool-delete-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_delete"
            />
            <AdminComponents.action_button
              id="pool-delete-submit"
              icon="hero-trash"
              label="Delete Pool"
              type="submit"
              variant={:danger}
              phx-click={
                JS.dispatch("blur", to: "#pool_delete_confirmation_slug_#{@delete_form_version}")
              }
              disabled={@deleting_pool.status != "archived"}
            />
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_delete">close</button>
      </form>
    </dialog>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  defp pool_filter_form(assigns) do
    ~H"""
    <AdminComponents.filter_form
      id="pool-filter-form"
      for={@form}
      phx-change="filter_pools"
      phx-submit="filter_pools"
      autocomplete="off"
    >
      <.pool_query_filter_input field={@form[:query]} />
      <.pool_status_filter_dropdown
        selected_value={@form[:status].value}
        selected={selected_pool_status_filter_option(@form[:status].value)}
      />
    </AdminComponents.filter_form>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp pool_query_filter_input(assigns) do
    assigns = assign(assigns, :value, pool_query_filter_value(assigns.field))

    ~H"""
    <div class="grid gap-2">
      <label for={@field.id} class="sr-only">Search</label>
      <div class="input input-bordered flex min-h-10 w-full items-center gap-2">
        <input
          id={@field.id}
          name={@field.name}
          type="text"
          value={@value}
          placeholder="Search pools..."
          class="peer grow text-sm font-normal"
        />
        <button
          id="pool-filter-query-clear"
          type="button"
          class="grid size-6 shrink-0 place-items-center rounded-full text-base-content/50 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary peer-placeholder-shown:hidden"
          phx-click="clear_pool_query_filter"
          aria-label="Clear pool search"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :selected_value, :string, required: true
  attr :selected, :map, required: true

  defp pool_status_filter_dropdown(assigns) do
    ~H"""
    <div class="grid gap-2">
      <label for="pool-status-filter" class="sr-only">Status</label>
      <input
        type="hidden"
        id="pool_filters_status"
        name="pool_filters[status]"
        value={@selected_value}
      />
      <details
        id="pool-status-filter"
        class="dropdown w-full"
        phx-click-away={JS.remove_attribute("open", to: "#pool-status-filter")}
      >
        <summary
          data-role="status-filter-trigger"
          class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
        >
          <.icon name={@selected.icon} class={["size-4 shrink-0", @selected.icon_class]} />
          <span class="truncate">{@selected.label}</span>
        </summary>
        <ul
          data-role="status-filter-menu"
          class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
        >
          <li :for={option <- pool_status_filter_options()}>
            <button
              type="button"
              phx-click="select_pool_status_filter"
              phx-value-status={option.value}
              data-role="status-filter-option"
              data-status={option.value}
              class={[
                "flex items-center gap-2 text-sm",
                option.value == @selected_value && "active"
              ]}
              aria-current={option.value == @selected_value && "true"}
            >
              <span data-role="status-filter-icon" class="shrink-0">
                <.icon name={option.icon} class={["size-4", option.icon_class]} />
              </span>
              <span class="truncate">{option.label}</span>
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  defp selected_pool_status_filter_option(status) do
    Enum.find(pool_status_filter_options(), &(&1.value == status)) ||
      all_pool_status_filter_option()
  end

  defp pool_status_filter_options do
    [
      all_pool_status_filter_option(),
      %{
        label: "Active",
        value: "active",
        icon: "hero-check-circle",
        icon_class: "text-success"
      },
      %{
        label: "Disabled",
        value: "disabled",
        icon: "hero-pause-circle",
        icon_class: "text-warning"
      },
      %{
        label: "Archived",
        value: "archived",
        icon: "hero-archive-box",
        icon_class: "text-error"
      }
    ]
  end

  defp all_pool_status_filter_option do
    %{
      label: "Status: All",
      value: "all",
      icon: "hero-server-stack",
      icon_class: "text-base-content/60"
    }
  end

  defp pool_query_filter_value(%{value: value}) when is_binary(value), do: value
  defp pool_query_filter_value(_field), do: ""

  attr :pools, :list, required: true
  attr :selected_pool_row, :any, default: nil
  attr :can_manage_pools?, :boolean, required: true

  defp pool_grid(assigns) do
    ~H"""
    <div
      id="pools-grid"
      class="grid min-w-0 gap-3 overflow-visible lg:grid-cols-2 2xl:grid-cols-3"
    >
      <.pool_card
        :for={pool_row <- @pools}
        pool_row={pool_row}
        selected_pool_row={@selected_pool_row}
        can_manage_pools?={@can_manage_pools?}
      />
    </div>
    """
  end

  attr :pool_row, :map, required: true
  attr :selected_pool_row, :any, default: nil
  attr :can_manage_pools?, :boolean, required: true

  defp pool_card(assigns) do
    ~H"""
    <article
      id={"pool-row-#{@pool_row.pool.id}"}
      class={[
        "pool-redesign-audit",
        @selected_pool_row && @selected_pool_row.pool.id == @pool_row.pool.id && "is-selected"
      ]}
    >
      <div class="audit-row audit-row-v2">
        <div class="audit-command-line">
          <div class="audit-identity">
            <button
              id={"inspect-pool-#{@pool_row.pool.id}"}
              type="button"
              class="audit-name text-left text-base-content transition-colors hover:text-primary"
              phx-click="select_pool"
              phx-value-id={@pool_row.pool.id}
            >
              {@pool_row.pool.name}
            </button>
            <p id={"pool-row-#{@pool_row.pool.id}-id"} class="audit-id">
              {@pool_row.pool.id}
            </p>
          </div>
          <div class="audit-states">
            <span
              id={"pool-row-#{@pool_row.pool.id}-status"}
              class={AdminBadges.lifecycle_chip_class(@pool_row.pool.status)}
            >
              {@pool_row.pool.status}
            </span>
            <span
              id={"pool-row-#{@pool_row.pool.id}-routing-strategy"}
              class={routing_strategy_class()}
            >
              {AdminBadges.routing_strategy_label(@pool_row.routing_strategy)}
            </span>
          </div>
          <.pool_action_menu pool_row={@pool_row} can_manage_pools?={@can_manage_pools?} />
        </div>
        <dl class="audit-metrics">
          <div class="audit-metric">
            <span>Upstreams</span>
            <span id={"pool-row-#{@pool_row.pool.id}-upstream-account-count"}>
              {@pool_row.upstream_count}
            </span>
          </div>
          <div class="audit-metric">
            <span>Keys</span>
            <span id={"pool-row-#{@pool_row.pool.id}-api-key-count"}>
              {@pool_row.api_key_count}
            </span>
          </div>
          <div class="audit-metric">
            <span>Requests</span>
            <span id={"pool-row-#{@pool_row.pool.id}-request-count-5h"}>
              {PoolsReadModel.format_metric_integer(@pool_row.request_count_5h)}
            </span>
          </div>
          <div class="audit-metric">
            <span>TPS</span>
            <span id={"pool-row-#{@pool_row.pool.id}-tokens-per-sec"}>
              {PoolsReadModel.format_metric_float(@pool_row.tokens_per_second)}
            </span>
          </div>
        </dl>
      </div>
      <.pool_quota_remaining_panel pool_row={@pool_row} />
    </article>
    """
  end

  attr :pool_row, :map, required: true

  defp pool_quota_remaining_panel(assigns) do
    assigns = assign(assigns, :quota_cards, quota_remaining_cards(assigns.pool_row))

    ~H"""
    <div
      id={"pool-row-#{@pool_row.pool.id}-quota-remaining"}
      data-role="pool-quota-remaining-panel"
      class="pool-quota-panel"
    >
      <div class="pool-quota-cards">
        <article
          :for={card <- @quota_cards}
          id={"pool-row-#{@pool_row.pool.id}-quota-#{card.id_suffix}"}
          data-role="pool-quota-remaining-card"
          class="pool-quota-card"
        >
          <div class="pool-quota-card-title">
            <h3>{card.title}</h3>
            <p>{card.summary_label}</p>
          </div>

          <div class="pool-quota-card-body">
            <div
              data-role="pool-quota-donut"
              class="pool-quota-donut"
              style={"background: #{card.gradient}"}
              role="img"
              aria-label={card.aria_label}
            >
              <div class="pool-quota-donut-center">
                <span>Remaining</span>
                <strong>{card.remaining_label}</strong>
              </div>
            </div>

            <div class="pool-quota-legend">
              <p :if={card.empty?} class="pool-quota-empty-copy">
                No current quota evidence
              </p>
              <div
                :for={segment <- card.legend_segments}
                class="pool-quota-legend-row"
              >
                <span class="pool-quota-legend-label">
                  <span class={["pool-quota-dot", segment.dot_class]}></span>
                  <span>{segment.label}</span>
                </span>
                <span class="pool-quota-legend-value">{segment.value_label}</span>
              </div>
            </div>
          </div>
        </article>
      </div>
    </div>
    """
  end

  attr :pool_row, :map, required: true
  attr :can_manage_pools?, :boolean, required: true

  defp pool_action_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end shrink-0">
      <button
        id={"pool-actions-menu-#{@pool_row.pool.id}"}
        type="button"
        class="btn btn-ghost btn-sm btn-square"
        tabindex="0"
        aria-label={"Actions for #{@pool_row.pool.name}"}
      >
        <.icon name="hero-ellipsis-vertical" class="size-5" />
      </button>
      <ul
        tabindex="0"
        class="menu dropdown-content z-20 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl"
      >
        <li>
          <AdminComponents.dropdown_action_item
            id={"edit-pool-#{@pool_row.pool.id}"}
            icon="hero-pencil-square"
            label="Edit"
            phx-click="edit_pool"
            phx-value-id={@pool_row.pool.id}
            disabled={!@can_manage_pools?}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"delete-pool-#{@pool_row.pool.id}"}
            icon="hero-trash"
            label="Delete"
            variant={:danger}
            phx-click="delete_pool"
            phx-value-id={@pool_row.pool.id}
            disabled={!@can_manage_pools? || @pool_row.pool.status != "archived"}
            title={PoolForm.delete_title(@pool_row.pool)}
          />
        </li>
      </ul>
    </div>
    """
  end

  defp routing_strategy_class do
    "#{AdminBadges.metadata_chip_class(:neutral)} whitespace-nowrap"
  end

  defp quota_remaining_cards(pool_row) do
    charts = Map.get(pool_row, :quota_remaining_charts, %{})

    Enum.map(@quota_chart_order, fn key ->
      charts
      |> Map.get(key, empty_quota_remaining_chart(key))
      |> quota_remaining_card()
    end)
  end

  defp empty_quota_remaining_chart(:primary_5h) do
    empty_quota_remaining_chart(:primary_5h, "5h Remaining")
  end

  defp empty_quota_remaining_chart(:weekly) do
    empty_quota_remaining_chart(:weekly, "Weekly Remaining")
  end

  defp empty_quota_remaining_chart(key, title) do
    %{
      key: key,
      title: title,
      remaining_total: Decimal.new(0),
      capacity_total: nil,
      used_total: nil,
      used_percent: nil,
      items: [],
      state: "empty"
    }
  end

  defp quota_remaining_card(chart) do
    capacity_total = Map.get(chart, :capacity_total)
    remaining_total = decimal_or_zero(Map.get(chart, :remaining_total))
    used_total = Map.get(chart, :used_total)
    items = Map.get(chart, :items, [])
    item_segments = Enum.map(items, &quota_item_segment(&1, capacity_total, remaining_total))
    used_segment = quota_used_segment(used_total, Map.get(chart, :used_percent), capacity_total)
    legend_segments = item_segments ++ Enum.reject([used_segment], &is_nil/1)
    empty? = legend_segments == []

    %{
      id_suffix: quota_chart_id_suffix(Map.get(chart, :key)),
      title: Map.get(chart, :title, "Quota Remaining"),
      summary_label: quota_summary_label(capacity_total, Map.get(chart, :used_percent)),
      remaining_label: format_quota_value(remaining_total),
      gradient: quota_gradient(legend_segments, capacity_total, remaining_total),
      legend_segments: legend_segments,
      empty?: empty?,
      aria_label:
        "#{Map.get(chart, :title, "Quota remaining")}: #{format_quota_value(remaining_total)} remaining"
    }
  end

  defp quota_chart_id_suffix(:primary_5h), do: "primary-5h"
  defp quota_chart_id_suffix(:weekly), do: "weekly"
  defp quota_chart_id_suffix(key), do: key |> to_string() |> String.replace("_", "-")

  defp quota_item_segment(item, capacity_total, remaining_total) do
    {dot_class, color} = quota_color(Map.get(item, :color_index, 0))
    remaining = decimal_or_zero(Map.get(item, :remaining))

    %{
      label: Map.get(item, :label) || "Upstream account",
      value: remaining,
      value_label: format_quota_value(remaining),
      percent: quota_segment_percent(remaining, capacity_total, remaining_total),
      dot_class: dot_class,
      color: color
    }
  end

  defp quota_used_segment(nil, _used_percent, _capacity_total), do: nil

  defp quota_used_segment(used_total, used_percent, capacity_total) do
    if decimal_positive?(used_total) do
      {dot_class, color} = @quota_used_color

      %{
        label: "Used",
        value: used_total,
        value_label: format_quota_value(used_total),
        percent: quota_used_percent(used_total, used_percent, capacity_total),
        dot_class: dot_class,
        color: color
      }
    end
  end

  defp quota_summary_label(nil, _used_percent), do: "Quota evidence only"

  defp quota_summary_label(capacity_total, used_percent) do
    "Total #{format_quota_value(capacity_total)} · #{format_quota_percent(used_percent)} used"
  end

  defp quota_segment_percent(value, capacity_total, remaining_total) do
    cond do
      decimal_positive?(capacity_total) -> decimal_percent(value, capacity_total)
      decimal_positive?(remaining_total) -> decimal_percent(value, remaining_total)
      true -> 0.0
    end
  end

  defp quota_used_percent(_used_total, %Decimal{} = used_percent, _capacity_total),
    do: decimal_to_float(used_percent)

  defp quota_used_percent(used_total, _used_percent, capacity_total) do
    if decimal_positive?(capacity_total),
      do: decimal_percent(used_total, capacity_total),
      else: 0.0
  end

  defp quota_gradient([], _capacity_total, _remaining_total), do: "var(--color-base-300)"

  defp quota_gradient(segments, _capacity_total, _remaining_total) do
    {stops, cursor} =
      Enum.reduce(segments, {[], 0.0}, fn segment, {stops, cursor} ->
        next_cursor = min(cursor + segment.percent, 100.0)

        {
          stops ++
            [
              "#{segment.color} #{Float.round(cursor, 2)}% #{Float.round(next_cursor, 2)}%"
            ],
          next_cursor
        }
      end)

    stops =
      if cursor < 100.0,
        do: stops ++ ["var(--color-base-300) #{Float.round(cursor, 2)}% 100%"],
        else: stops

    "conic-gradient(#{Enum.join(stops, ", ")})"
  end

  defp quota_color(index) when is_integer(index) do
    Enum.at(@quota_chart_colors, rem(max(index, 0), length(@quota_chart_colors)))
  end

  defp quota_color(_index), do: List.first(@quota_chart_colors)

  defp decimal_percent(value, total) do
    value
    |> Decimal.div(total)
    |> Decimal.mult(Decimal.new(100))
    |> decimal_to_float()
  end

  defp decimal_positive?(%Decimal{} = value), do: Decimal.compare(value, Decimal.new(0)) == :gt
  defp decimal_positive?(value) when is_integer(value), do: value > 0
  defp decimal_positive?(value) when is_float(value), do: value > 0
  defp decimal_positive?(_value), do: false

  defp decimal_or_zero(%Decimal{} = value), do: value
  defp decimal_or_zero(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_or_zero(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal_or_zero(_value), do: Decimal.new(0)

  defp decimal_to_float(%Decimal{} = value), do: Decimal.to_float(value)

  defp format_quota_percent(%Decimal{} = percent) do
    percent
    |> decimal_to_float()
    |> Float.round(1)
    |> compact_float()
    |> Kernel.<>("%")
  end

  defp format_quota_percent(_percent), do: "unknown"

  defp format_quota_value(nil), do: "unknown"

  defp format_quota_value(%Decimal{} = value) do
    number = value |> decimal_to_float() |> max(0.0)

    cond do
      number >= 1_000_000_000 -> "#{compact_float(number / 1_000_000_000)}B"
      number >= 1_000_000 -> "#{compact_float(number / 1_000_000)}M"
      number >= 1_000 -> "#{compact_float(number / 1_000)}K"
      number >= 100 -> Integer.to_string(round(number))
      true -> compact_float(number)
    end
  end

  defp compact_float(value) do
    decimals = if value < 10 and value != Float.round(value, 0), do: 2, else: 1
    rounded = Float.round(value, decimals)

    rounded
    |> :erlang.float_to_binary(decimals: decimals)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end
end
