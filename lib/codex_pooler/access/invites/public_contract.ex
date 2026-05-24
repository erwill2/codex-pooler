defmodule CodexPooler.Access.Invites.PublicContract do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.Invite
  alias CodexPooler.Accounts.User
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @type t :: %{
          required(:status) => String.t(),
          required(:invite) => %{
            required(:invite_id) => Ecto.UUID.t(),
            required(:pool_id) => Ecto.UUID.t(),
            required(:pool_slug) => String.t(),
            required(:pool_name) => String.t(),
            required(:invited_email) => String.t(),
            required(:inviter_label) => String.t(),
            required(:status) => String.t(),
            required(:expires_at) => String.t() | nil,
            required(:available_methods) => [String.t()],
            required(:wizard_path) => String.t()
          }
        }

  @spec build(Invite.t(), Pool.t(), String.t()) :: t()
  def build(%Invite{} = invite, %Pool{} = pool, raw_token) when is_binary(raw_token) do
    %{
      status: "ok",
      invite: %{
        invite_id: invite.id,
        pool_id: pool.id,
        pool_slug: pool.slug,
        pool_name: pool.name,
        invited_email: invite.invited_email,
        inviter_label: inviter_label(invite.created_by_user_id),
        status: invite.status,
        expires_at: invite.expires_at && DateTime.to_iso8601(invite.expires_at),
        available_methods: ["device"],
        wizard_path: "/onboarding/invites/#{raw_token}"
      }
    }
  end

  defp inviter_label(user_id) when is_binary(user_id) do
    case Repo.one(from user in User, where: user.id == ^user_id and is_nil(user.deleted_at)) do
      %User{email: email} when is_binary(email) -> email
      _user -> "iCoreTech operator"
    end
  end

  defp inviter_label(_user_id), do: "iCoreTech operator"
end
