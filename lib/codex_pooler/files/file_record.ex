defmodule CodexPooler.Files.FileRecord do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @statuses ~w(pending_upload uploaded abandoned expired deleted)
  @finalize_statuses ~w(pending succeeded failed)

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type status :: String.t()
  @type finalize_status :: String.t()

  schema "codex_files" do
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :request_id, :binary_id
    field :file_id, :string
    field :purpose, :string
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :status, :string
    field :pool_upstream_assignment_id, :binary_id
    field :upstream_identity_id, :binary_id
    field :finalize_status, :string
    field :uploaded_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
    field :metadata, :map
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :pool_id,
      :api_key_id,
      :request_id,
      :file_id,
      :purpose,
      :filename,
      :content_type,
      :byte_size,
      :status,
      :pool_upstream_assignment_id,
      :upstream_identity_id,
      :finalize_status,
      :uploaded_at,
      :expires_at,
      :deleted_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_required([
      :pool_id,
      :api_key_id,
      :file_id,
      :purpose,
      :filename,
      :byte_size,
      :status,
      :finalize_status,
      :expires_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:finalize_status, @finalize_statuses)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec finalize_statuses() :: [finalize_status()]
  def finalize_statuses, do: @finalize_statuses

  @spec pending_upload_status() :: status()
  def pending_upload_status, do: "pending_upload"

  @spec uploaded_status() :: status()
  def uploaded_status, do: "uploaded"

  @spec abandoned_status() :: status()
  def abandoned_status, do: "abandoned"

  @spec expired_status() :: status()
  def expired_status, do: "expired"

  @spec deleted_status() :: status()
  def deleted_status, do: "deleted"

  @spec pending_finalize_status() :: finalize_status()
  def pending_finalize_status, do: "pending"

  @spec succeeded_finalize_status() :: finalize_status()
  def succeeded_finalize_status, do: "succeeded"

  @spec failed_finalize_status() :: finalize_status()
  def failed_finalize_status, do: "failed"
end
