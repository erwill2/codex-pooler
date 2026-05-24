defmodule CodexPooler.Gateway.Persistence.BridgeDemotion do
  @moduledoc false
  use CodexPooler.Schema

  @type status :: String.t()
  @type t :: %__MODULE__{}

  schema "bridge_demotions" do
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :model_identifier, :string
    field :pool_upstream_assignment_id, :binary_id
    field :upstream_identity_id, :binary_id
    field :reason_code, :string
    field :status, :string
    field :demoted_until, :utc_datetime_usec
    field :last_request_id, :binary_id
    field :attempt_count, :integer
    field :metadata, :map
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec active_status() :: status()
  def active_status, do: "active"

  @spec resolved_status() :: status()
  def resolved_status, do: "resolved"
end
