defmodule CodexPooler.Repo.Migrations.CreateRequestLogFacts do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists table(:request_log_facts, primary_key: false) do
      add :request_id,
          references(:requests, type: :binary_id, on_delete: :delete_all),
          null: false,
          primary_key: true

      add :latest_attempt_id, references(:attempts, type: :binary_id, on_delete: :nilify_all)
      add :latest_attempt_number, :integer
      add :latest_attempt_status, :string
      add :latest_attempt_retryable, :boolean
      add :latest_upstream_status_code, :integer

      add :latest_pool_upstream_assignment_id,
          references(:pool_upstream_assignments, type: :binary_id, on_delete: :nilify_all)

      add :latest_upstream_identity_id,
          references(:upstream_identities, type: :binary_id, on_delete: :nilify_all)

      add :latest_network_error_code, :string
      add :latest_latency_ms, :integer

      add :latest_settlement_entry_id,
          references(:ledger_entries, type: :binary_id, on_delete: :nilify_all)

      add :latest_settlement_usage_status, :string
      add :latest_settlement_pricing_status, :string
      add :latest_input_tokens, :bigint
      add :latest_cached_input_tokens, :bigint
      add :latest_output_tokens, :bigint
      add :latest_reasoning_tokens, :bigint
      add :latest_total_tokens, :bigint
      add :latest_settled_cost_micros, :bigint
      add :latest_cached_input_cost_micros, :bigint
      add :latest_cached_input_token_micros, :bigint
      add :latest_settlement_occurred_at, :utc_datetime_usec
      add :latest_settlement_created_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    execute """
    INSERT INTO request_log_facts (
      request_id,
      latest_attempt_id,
      latest_attempt_number,
      latest_attempt_status,
      latest_attempt_retryable,
      latest_upstream_status_code,
      latest_pool_upstream_assignment_id,
      latest_upstream_identity_id,
      latest_network_error_code,
      latest_latency_ms,
      latest_settlement_entry_id,
      latest_settlement_usage_status,
      latest_settlement_pricing_status,
      latest_input_tokens,
      latest_cached_input_tokens,
      latest_output_tokens,
      latest_reasoning_tokens,
      latest_total_tokens,
      latest_settled_cost_micros,
      latest_cached_input_cost_micros,
      latest_cached_input_token_micros,
      latest_settlement_occurred_at,
      latest_settlement_created_at,
      inserted_at,
      updated_at
    )
    SELECT
      request.id,
      latest_attempt.id,
      latest_attempt.attempt_number,
      latest_attempt.status,
      latest_attempt.retryable,
      latest_attempt.upstream_status_code,
      latest_attempt.pool_upstream_assignment_id,
      latest_attempt.upstream_identity_id,
      latest_attempt.network_error_code,
      latest_attempt.latency_ms,
      latest_settlement.id,
      latest_settlement.usage_status,
      latest_settlement.details->>'pricing_status',
      latest_settlement.input_tokens,
      latest_settlement.cached_input_tokens,
      latest_settlement.output_tokens,
      latest_settlement.reasoning_tokens,
      latest_settlement.total_tokens,
      (latest_settlement.details->>'settled_cost_micros')::numeric::bigint,
      (latest_settlement.details->>'cached_input_cost_micros')::numeric::bigint,
      pricing.cached_input_token_micros::bigint,
      latest_settlement.occurred_at,
      latest_settlement.created_at,
      NOW(),
      NOW()
    FROM requests AS request
    LEFT JOIN LATERAL (
      SELECT attempt.*
      FROM attempts AS attempt
      WHERE attempt.request_id = request.id
      ORDER BY attempt.attempt_number DESC, attempt.id DESC
      LIMIT 1
    ) AS latest_attempt ON TRUE
    LEFT JOIN LATERAL (
      SELECT entry.*
      FROM ledger_entries AS entry
      WHERE entry.request_id = request.id
        AND entry.entry_kind = 'settlement'
        AND entry.amount_status = 'recorded'
      ORDER BY entry.occurred_at DESC, entry.created_at DESC, entry.id DESC
      LIMIT 1
    ) AS latest_settlement ON TRUE
    LEFT JOIN pricing_snapshots AS pricing
      ON pricing.id = latest_settlement.pricing_snapshot_id
    ON CONFLICT (request_id) DO NOTHING
    """

    create_if_not_exists index(:request_log_facts, [:latest_upstream_identity_id, :request_id],
                           name: :request_log_facts_latest_upstream_identity_request_idx,
                           where: "latest_upstream_identity_id IS NOT NULL",
                           concurrently: true
                         )
  end
end
