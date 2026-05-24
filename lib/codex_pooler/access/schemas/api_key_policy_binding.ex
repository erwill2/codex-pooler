defmodule CodexPooler.Access.APIKeyPolicyBinding do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type attrs :: map()

  schema "api_key_policy_bindings" do
    field :api_key_id, :binary_id
    field :binding_scope, :string
    field :model_identifier, :string
    field :status, :string
    field :max_requests_per_minute, :integer
    field :max_tokens_per_day, :integer
    field :max_tokens_per_week, :integer
    field :max_input_tokens_per_request, :integer
    field :max_output_tokens_per_request, :integer
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [
      :api_key_id,
      :binding_scope,
      :model_identifier,
      :status,
      :max_requests_per_minute,
      :max_tokens_per_day,
      :max_tokens_per_week,
      :max_input_tokens_per_request,
      :max_output_tokens_per_request,
      :created_at,
      :updated_at
    ])
    |> update_change(:model_identifier, &normalize_model_identifier/1)
    |> validate_required([:api_key_id, :binding_scope, :status])
    |> validate_inclusion(:binding_scope, ["default", "model"])
    |> validate_inclusion(:status, ["active", "disabled"])
    |> validate_policy_shape()
    |> validate_number(:max_requests_per_minute, greater_than: 0)
    |> validate_number(:max_tokens_per_day, greater_than: 0)
    |> validate_number(:max_tokens_per_week, greater_than: 0)
    |> validate_number(:max_input_tokens_per_request, greater_than: 0)
    |> validate_number(:max_output_tokens_per_request, greater_than: 0)
    |> unique_constraint(:api_key_id, name: :api_key_policy_default_active_uq)
    |> unique_constraint(:model_identifier, name: :api_key_policy_model_active_uq)
  end

  defp validate_policy_shape(changeset) do
    case {get_field(changeset, :binding_scope), get_field(changeset, :model_identifier)} do
      {"default", nil} ->
        changeset

      {"model", model_identifier} when is_binary(model_identifier) ->
        changeset

      {"default", _model_identifier} ->
        add_error(changeset, :model_identifier, "must be empty for default policy bindings")

      {"model", _model_identifier} ->
        add_error(changeset, :model_identifier, "is required for model policy bindings")

      _other ->
        changeset
    end
  end

  defp normalize_model_identifier(nil), do: nil

  defp normalize_model_identifier(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end
end
