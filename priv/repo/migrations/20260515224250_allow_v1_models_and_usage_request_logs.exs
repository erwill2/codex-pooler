defmodule CodexPooler.Repo.Migrations.AllowV1ModelsAndUsageRequestLogs do
  use Ecto.Migration

  def change do
    execute(
      """
      ALTER TABLE requests
      DROP CONSTRAINT requests_endpoint_check,
      ADD CONSTRAINT requests_endpoint_check CHECK ((endpoint = ANY (ARRAY[
        '/backend-api/codex/models'::text,
        '/backend-api/codex/responses'::text,
        '/backend-api/codex/responses/compact'::text,
        '/backend-api/transcribe'::text,
        '/backend-api/files'::text,
        '/backend-api/files/uploaded'::text,
        '/api/codex/usage'::text,
        '/wham/usage'::text,
        '/backend-api/wham/usage'::text,
        '/v1/models'::text,
        '/v1/usage'::text
      ])))
      """,
      """
      ALTER TABLE requests
      DROP CONSTRAINT requests_endpoint_check,
      ADD CONSTRAINT requests_endpoint_check CHECK ((endpoint = ANY (ARRAY[
        '/backend-api/codex/models'::text,
        '/backend-api/codex/responses'::text,
        '/backend-api/codex/responses/compact'::text,
        '/backend-api/transcribe'::text,
        '/backend-api/files'::text,
        '/backend-api/files/uploaded'::text,
        '/api/codex/usage'::text,
        '/wham/usage'::text,
        '/backend-api/wham/usage'::text
      ])))
      """
    )
  end
end
