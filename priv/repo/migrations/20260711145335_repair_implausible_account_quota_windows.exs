defmodule CodexPooler.Repo.Migrations.RepairImplausibleAccountQuotaWindows do
  use Ecto.Migration

  @moduledoc """
  Data repair for quota evidence rows written before the same-cycle liveness
  fix. Two classes of rows cannot self-heal through account reconciliation:

  1. Rows whose reset horizon is implausibly far beyond their own window
     duration (for example a 5h window with a reset weeks away). Earlier
     merge logic could promote a stale relative countdown into such a reset,
     and later valid snapshots always look same-cycle-backward against it,
     so the wrong reset is defended until it finally passes.
  2. Rows whose reset passed more than a day ago. They are dead evidence that
     only survives on identities that stopped reconciling (for example
     reauth-required identities) and can confuse operator displays.

  Quota evidence is rebuilt automatically: account reconciliation reinserts
  usage snapshots for active identities within minutes, and response-header
  evidence rebuilds on dispatched traffic. Deleting these rows loses nothing
  durable.
  """

  def up do
    execute """
    DELETE FROM account_quota_windows
    WHERE reset_at IS NOT NULL
      AND observed_at IS NOT NULL
      AND window_minutes IS NOT NULL
      AND reset_at > observed_at + (window_minutes * INTERVAL '1 minute') + INTERVAL '1 hour'
    """

    execute """
    DELETE FROM account_quota_windows
    WHERE reset_at IS NOT NULL
      AND reset_at < now() - INTERVAL '24 hours'
    """
  end

  def down do
    # Data-only repair. Deleted evidence rows are operational cache rebuilt by
    # account reconciliation and runtime traffic; there is nothing to restore.
    :ok
  end
end
