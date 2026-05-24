defmodule CodexPooler.Files.FileState do
  @moduledoc false

  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Repo

  @spec complete_upload!(FileRecord.t(), DateTime.t()) :: FileRecord.t()
  def complete_upload!(%FileRecord{} = file, now) do
    file
    |> Ecto.Changeset.change(%{
      status: FileRecord.uploaded_status(),
      finalize_status: FileRecord.succeeded_finalize_status(),
      uploaded_at: now,
      updated_at: now
    })
    |> Repo.update!()
  end

  @spec fail_finalize!(FileRecord.t(), DateTime.t()) :: FileRecord.t()
  def fail_finalize!(%FileRecord{} = file, now) do
    file
    |> Ecto.Changeset.change(%{
      status: FileRecord.abandoned_status(),
      finalize_status: FileRecord.failed_finalize_status(),
      updated_at: now
    })
    |> Repo.update!()
  end

  @spec expire!(FileRecord.t(), DateTime.t()) :: FileRecord.t()
  def expire!(%FileRecord{} = file, now) do
    file
    |> Ecto.Changeset.change(%{
      status: FileRecord.expired_status(),
      deleted_at: now,
      updated_at: now
    })
    |> Repo.update!()
  end

  @spec expired?(FileRecord.t(), DateTime.t()) :: boolean()
  def expired?(%FileRecord{} = file, now), do: DateTime.compare(file.expires_at, now) != :gt

  @spec classify(FileRecord.t() | nil, DateTime.t()) ::
          :missing | :expired | :uploaded | :local_pending | :upstream_pending | :not_uploadable
  def classify(nil, _now), do: :missing

  def classify(%FileRecord{} = file, now) do
    cond do
      file.status == FileRecord.expired_status() or expired?(file, now) ->
        :expired

      file.status == FileRecord.uploaded_status() ->
        :uploaded

      file.status == FileRecord.pending_upload_status() and
          is_nil(file.pool_upstream_assignment_id) ->
        :local_pending

      file.status == FileRecord.pending_upload_status() ->
        :upstream_pending

      true ->
        :not_uploadable
    end
  end
end
