defmodule CodexPooler.Repo.Migrations.AddInviteEmailSentAt do
  use Ecto.Migration

  def change do
    alter table(:invites) do
      add :email_sent_at, :utc_datetime_usec
    end
  end
end
