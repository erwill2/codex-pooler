defmodule CodexPooler.Repo.Migrations.AddRequestsApiKeyAdmittedIndex do
  use Ecto.Migration

  def change do
    execute(
      "CREATE INDEX requests_api_key_admitted_idx ON requests (api_key_id, admitted_at DESC, id DESC)",
      "DROP INDEX requests_api_key_admitted_idx"
    )
  end
end
