defmodule CodexPooler.Repo do
  use Ecto.Repo,
    otp_app: :codex_pooler,
    adapter: Ecto.Adapters.Postgres
end
