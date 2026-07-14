defmodule CodexPooler.Repo.Migrations.PurgePriorCycleQuotaWindows do
  use Ecto.Migration

  @moduledoc """
  Data repair for quota evidence rows stranded on an ended weekly cycle.

  When a weekly window restarts (naturally or through a saved-reset
  redemption), runtime evidence rows recorded during the ended cycle are never
  re-observed without new dispatched traffic, so they survive with the old
  cycle's reset and a pessimistic used percent. Selection ranks pressure ahead
  of freshness, so those rows kept winning the operator display (observed
  live: a rate-limit-event row at 94 percent from the ended cycle rendered as
  6 percent remaining while the account was genuinely unused).

  A stale row whose same-window sibling was observed later and carries a reset
  a full margin beyond it is describing a cycle the provider already replaced.
  Fresh rows are left untouched — same-cycle resets legitimately drift across
  provider surfaces — and groups with no newer-cycle sibling keep their
  fail-closed pessimism (an exhausted account with no newer evidence stays
  exhausted). Quota evidence rebuilds automatically: reconciliation reinserts
  usage snapshots within minutes and runtime evidence rebuilds on dispatched
  traffic, so deleting these rows loses nothing durable.
  """

  def up do
    execute """
    DELETE FROM account_quota_windows AS stranded
    WHERE stranded.reset_at IS NOT NULL
      AND stranded.observed_at IS NOT NULL
      AND stranded.observed_at < now() - INTERVAL '15 minutes'
      AND EXISTS (
        SELECT 1
        FROM account_quota_windows AS sibling
        WHERE sibling.upstream_identity_id = stranded.upstream_identity_id
          AND sibling.id <> stranded.id
          AND sibling.quota_key = stranded.quota_key
          AND COALESCE(sibling.quota_scope, 'account') = COALESCE(stranded.quota_scope, 'account')
          AND COALESCE(sibling.quota_family, 'account') = COALESCE(stranded.quota_family, 'account')
          AND COALESCE(lower(sibling.model), '') = COALESCE(lower(stranded.model), '')
          AND COALESCE(lower(sibling.upstream_model), '') = COALESCE(lower(stranded.upstream_model), '')
          AND sibling.window_minutes = stranded.window_minutes
          AND (CASE
                 WHEN sibling.window_kind = 'primary' AND sibling.window_minutes = 10080
                   THEN 'secondary'
                 ELSE sibling.window_kind
               END) = (CASE
                 WHEN stranded.window_kind = 'primary' AND stranded.window_minutes = 10080
                   THEN 'secondary'
                 ELSE stranded.window_kind
               END)
          AND sibling.reset_at IS NOT NULL
          AND sibling.observed_at IS NOT NULL
          AND sibling.observed_at > stranded.observed_at
          AND sibling.reset_at > stranded.reset_at + INTERVAL '1 hour'
      )
    """
  end

  def down do
    # Data-only repair. Deleted evidence rows are operational cache rebuilt by
    # account reconciliation and runtime traffic; there is nothing to restore.
    :ok
  end
end
