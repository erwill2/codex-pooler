defmodule CodexPooler.Accounting.HourlyModelUsageRollup do
  @moduledoc false
  use CodexPooler.Schema

  @type t :: %__MODULE__{}

  schema "hourly_model_usage_rollups" do
    field :bucket_started_at, :utc_datetime_usec
    field :pool_id, :binary_id
    field :model_id, :binary_id
    field :model_code, :string
    field :request_count, :integer
    field :success_count, :integer
    field :failure_count, :integer
    field :retry_count, :integer
    field :input_tokens, :integer
    field :cached_input_tokens, :integer
    field :output_tokens, :integer
    field :reasoning_tokens, :integer
    field :total_tokens, :integer
    field :estimated_cost_micros, :decimal
    field :settled_cost_micros, :decimal
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
