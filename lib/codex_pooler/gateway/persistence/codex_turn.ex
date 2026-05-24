defmodule CodexPooler.Gateway.Persistence.CodexTurn do
  @moduledoc false
  use CodexPooler.Schema

  @type t :: %__MODULE__{}

  schema "codex_turns" do
    field :codex_session_id, :binary_id
    field :request_id, :binary_id
    field :turn_sequence, :integer
    field :transport_kind, :string
    field :status, :string
    field :error_code, :string
    field :first_visible_output_at, :utc_datetime_usec
    field :final_attempt_id, :binary_id
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
