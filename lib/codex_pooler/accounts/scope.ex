defmodule CodexPooler.Accounts.Scope do
  @moduledoc """
  Caller scope passed through context APIs for authorization, audit, and
  pool-scoped UI invalidation.
  """

  alias CodexPooler.Accounts.User

  defstruct user: nil, roles: []

  @type t :: %__MODULE__{user: User.t() | nil, roles: [String.t()]}

  @spec for_user(User.t() | nil, [String.t()]) :: t() | nil
  def for_user(user, roles \\ [])

  def for_user(%User{} = user, roles) do
    %__MODULE__{user: user, roles: roles}
  end

  def for_user(nil, _roles), do: nil
end
