defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.TokenBurnPopover do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Format

  attr :id, :string, required: true
  attr :content_id, :string, required: true
  attr :account, :map, required: true

  def token_burn_popover(assigns) do
    assigns = assign(assigns, :token_burn, token_burn(assigns.account))

    ~H"""
    <span
      id={"#{@id}-popover"}
      data-role="upstream-token-burn-popover"
      class="dropdown dropdown-end dropdown-bottom inline-flex justify-end"
    >
      <button
        id={@id}
        type="button"
        class="inline-flex cursor-pointer items-center justify-end gap-1 rounded px-1 text-xs font-medium text-base-content/70 transition-colors hover:bg-base-300/60 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        tabindex="0"
        aria-label="Token burn calculation"
        aria-haspopup="true"
        aria-describedby={@content_id}
      >
        <.icon name="hero-fire" class={token_burn_icon_class(@token_burn)} />
        <span>{@token_burn.label}</span>
      </button>
      <span
        id={@content_id}
        role="tooltip"
        tabindex="0"
        class="dropdown-content z-50 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-3 text-left text-xs font-normal leading-5 text-base-content/70 shadow-xl sm:w-72"
      >
        <span class="block">
          Compares settled tokens from the last 5 minutes with the previous 1 hour baseline.
        </span>
        <span class="mt-2 grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1">
          <span class="font-medium text-base-content/55">Last 5 minutes</span>
          <span class="text-base-content">{token_burn_recent_token_label(@token_burn)}</span>
          <span class="font-medium text-base-content/55">Previous 1 hour</span>
          <span class="text-base-content">{token_burn_baseline_token_label(@token_burn)}</span>
        </span>
      </span>
    </span>
    """
  end

  defp token_burn(%{token_burn: token_burn}) when is_map(token_burn), do: token_burn

  defp token_burn(_account) do
    %{
      level: 0,
      label: "x0",
      title: "last 5m: 0 tokens; previous 1h: 0 tokens",
      recent_tokens: 0,
      baseline_tokens: 0
    }
  end

  defp token_burn_recent_token_label(%{recent_tokens: tokens})
       when is_integer(tokens) and tokens >= 0 do
    "#{Format.token_count(tokens)} tokens"
  end

  defp token_burn_recent_token_label(_token_burn), do: "0 tokens"

  defp token_burn_baseline_token_label(%{baseline_tokens: tokens})
       when is_integer(tokens) and tokens >= 0 do
    "#{Format.token_count(tokens)} tokens"
  end

  defp token_burn_baseline_token_label(_token_burn), do: "0 tokens"

  defp token_burn_icon_class(%{level: 0}), do: "size-3.5 text-base-content/35"
  defp token_burn_icon_class(%{level: level}) when level in 1..2, do: "size-3.5 text-warning/70"
  defp token_burn_icon_class(%{level: level}) when level in 3..4, do: "size-3.5 text-warning"
  defp token_burn_icon_class(%{level: 5}), do: "size-3.5 text-error"
  defp token_burn_icon_class(_token_burn), do: "size-3.5 text-base-content/35"
end
