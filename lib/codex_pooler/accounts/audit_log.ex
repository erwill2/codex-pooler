defmodule CodexPooler.Accounts.AuditLog do
  @moduledoc false

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit
  alias CodexPooler.Postgres.INET

  @type audit_result :: Audit.audit_result() | {:ok, nil}

  @type event_attrs :: %{
          required(:action) => String.t(),
          required(:target_type) => String.t(),
          optional(:target_id) => Ecto.UUID.t() | nil,
          optional(:metadata) => map(),
          optional(:details) => map()
        }

  @spec record_user_event(User.t() | Scope.t() | term(), event_attrs()) :: audit_result()
  def record_user_event(actor, attrs)

  def record_user_event(%User{} = user, attrs) when is_map(attrs) do
    metadata = Map.get(attrs, :metadata, %{})

    Audit.record_user_event(user, %{
      action: Map.fetch!(attrs, :action),
      target_type: Map.fetch!(attrs, :target_type),
      target_id: Map.get(attrs, :target_id),
      correlation_id: Map.get(attrs, :correlation_id) || metadata_value(metadata, :request_id),
      ip_address: Map.get(attrs, :ip_address) || inet(metadata_value(metadata, :ip_address)),
      details: Map.get(attrs, :details, %{})
    })
  end

  def record_user_event(%Scope{user: %User{} = user}, attrs) when is_map(attrs) do
    record_user_event(user, attrs)
  end

  def record_user_event(_actor, attrs) when is_map(attrs), do: {:ok, nil}

  defp metadata_value(metadata, key) when is_map(metadata), do: Map.get(metadata, key)
  defp metadata_value(_metadata, _key), do: nil

  defp inet(value) do
    case INET.cast(value) do
      {:ok, inet} -> inet
      :error -> nil
    end
  end
end
