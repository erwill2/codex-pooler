defmodule CodexPooler.Files.UploadLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Files.{FileRecord, FileState, RequestLog, RequestMetadata}
  alias CodexPooler.Repo

  @type auth :: CodexPooler.Access.auth_context()
  @type file_id :: String.t()
  @type file_error :: CodexPooler.Files.file_error()
  @type finalize_bridge_result :: CodexPooler.Files.finalize_bridge_result()
  @type file_result :: CodexPooler.Files.file_result()

  @spec record_upload_failure(auth(), file_id(), map(), RequestMetadata.t() | map() | keyword()) ::
          {:error, file_error()}
  def record_upload_failure(auth, file_id, upload_error, opts \\ %{})

  def record_upload_failure(
        %{pool: pool, api_key: api_key} = auth,
        file_id,
        %{status: status, code: code} = upload_error,
        opts
      )
      when is_binary(file_id) do
    request_opts = create_file_request_opts(opts)
    now = now(opts)

    case Repo.transaction(fn ->
           auth
           |> locked_owned_file(file_id, pool.id, api_key.id)
           |> record_upload_failure_file(auth, file_id, request_opts, status, code, now)
         end) do
      {:ok, {:ok, _request}} -> {:error, Map.drop(upload_error, [:upstream])}
      {:error, reason} -> {:error, reason}
    end
  end

  def record_upload_failure(_auth, _file_id, _upload_error, _opts),
    do: {:error, error(400, :invalid_request, "authenticated pool and api key are required")}

  @spec mark_uploaded_or_prepare_finalize(auth(), file_id(), map(), DateTime.t()) ::
          {:finalize, FileRecord.t()} | file_result()
  def mark_uploaded_or_prepare_finalize(
        %{pool: pool, api_key: api_key} = auth,
        file_id,
        request_opts,
        now
      ) do
    case Repo.transaction(fn ->
           auth
           |> locked_owned_file(file_id, pool.id, api_key.id)
           |> handle_mark_uploaded_file(auth, file_id, request_opts, now)
         end) do
      {:ok, {:finalize, %FileRecord{} = file}} -> {:finalize, file}
      result -> unwrap_nested_transaction(result)
    end
  end

  def mark_uploaded_or_prepare_finalize(_auth, _file_id, _request_opts, _now),
    do: {:error, error(400, :invalid_request, "authenticated pool and api key are required")}

  @spec record_finalize_result(auth(), file_id(), RequestMetadata.t(), finalize_bridge_result()) ::
          file_result()
  def record_finalize_result(
        %{pool: pool, api_key: api_key} = auth,
        file_id,
        request_opts,
        bridge_result
      ) do
    now = now(request_opts)

    Repo.transaction(fn ->
      auth
      |> locked_owned_file(file_id, pool.id, api_key.id)
      |> record_finalize_result_file(auth, file_id, request_opts, bridge_result, now)
    end)
    |> unwrap_nested_transaction()
  end

  def record_finalize_result(_auth, _file_id, _request_opts, _bridge_result),
    do: {:error, error(400, :invalid_request, "authenticated pool and api key are required")}

  defp locked_owned_file(_auth, file_id, pool_id, api_key_id) do
    Repo.one(
      from file in FileRecord,
        where:
          file.file_id == ^file_id and file.pool_id == ^pool_id and
            file.api_key_id == ^api_key_id,
        lock: "FOR UPDATE"
    )
  end

  defp handle_mark_uploaded_file(nil, auth, _file_id, request_opts, _now) do
    with {:ok, _request} <-
           record_file_request_or_rollback(auth, "failed", 404, request_opts, %{
             "file" => %{"lookup" => "not_found"},
             "operation" => "uploaded",
             "error_code" => "file_not_found"
           }) do
      {:error, error(404, :file_not_found, "file was not found")}
    end
  end

  defp handle_mark_uploaded_file(file, auth, file_id, request_opts, now) do
    case FileState.classify(file, now) do
      :expired -> record_file_expired!(auth, file, file_id, request_opts, now)
      :uploaded -> record_uploaded_file(file, auth, file_id, request_opts)
      :local_pending -> complete_local_pending_file!(auth, file, file_id, request_opts, now)
      :upstream_pending -> {:finalize, file}
      :not_uploadable -> record_file_not_uploadable!(auth, file_id, request_opts)
    end
  end

  defp record_uploaded_file(file, auth, file_id, request_opts) do
    with {:ok, request} <-
           record_file_request_or_rollback(auth, "succeeded", 200, request_opts, %{
             "file" => %{"id" => file_id},
             "operation" => "uploaded"
           }) do
      {:ok, %{file: file, request: request}}
    end
  end

  defp record_finalize_result_file(nil, auth, _file_id, request_opts, _bridge_result, _now) do
    with {:ok, _request} <-
           record_file_request_or_rollback(auth, "failed", 404, request_opts, %{
             "file" => %{"lookup" => "not_found"},
             "operation" => "uploaded",
             "error_code" => "file_not_found"
           }) do
      {:error, error(404, :file_not_found, "file was not found")}
    end
  end

  defp record_finalize_result_file(file, auth, file_id, request_opts, bridge_result, now) do
    case FileState.classify(file, now) do
      :expired ->
        record_file_expired!(auth, file, file_id, request_opts, now)

      :uploaded ->
        record_uploaded_file(file, auth, file_id, request_opts)

      :local_pending ->
        complete_local_pending_file!(auth, file, file_id, request_opts, now)

      :upstream_pending ->
        record_pending_finalize_result!(auth, file, file_id, request_opts, bridge_result, now)

      :not_uploadable ->
        record_file_not_uploadable!(auth, file_id, request_opts)
    end
  end

  defp record_file_expired!(auth, file, file_id, request_opts, now) do
    FileState.expire!(file, now)

    with {:ok, _request} <-
           record_file_request_or_rollback(auth, "failed", 410, request_opts, %{
             "file" => %{"id" => file_id},
             "operation" => "uploaded",
             "error_code" => "file_expired"
           }) do
      {:error, error(410, :file_expired, "file upload has expired")}
    end
  end

  defp record_file_not_uploadable!(auth, file_id, request_opts) do
    with {:ok, _request} <-
           record_file_request_or_rollback(auth, "failed", 409, request_opts, %{
             "file" => %{"id" => file_id},
             "operation" => "uploaded",
             "error_code" => "file_not_uploadable"
           }) do
      {:error, error(409, :file_not_uploadable, "file cannot be marked uploaded")}
    end
  end

  defp complete_local_pending_file!(auth, file, file_id, request_opts, now) do
    file = FileState.complete_upload!(file, now)

    with {:ok, request} <-
           record_file_request_or_rollback(auth, "succeeded", 200, request_opts, %{
             "file" => %{"id" => file_id},
             "operation" => "uploaded"
           }) do
      {:ok, %{file: file, request: request}}
    end
  end

  defp record_pending_finalize_result!(auth, file, file_id, request_opts, bridge_result, now) do
    case bridge_result do
      {:ok, %{body: body} = bridge_result} ->
        record_finalize_success_or_incomplete(
          auth,
          file,
          file_id,
          request_opts,
          bridge_result,
          now,
          body
        )

      {:retry_timeout, %{body: body} = bridge_result} ->
        record_finalize_retry_timeout(auth, file, file_id, request_opts, bridge_result, body)

      {:error, %{status: status} = bridge_error} ->
        record_finalize_bridge_error(auth, file, file_id, request_opts, bridge_error, status, now)
    end
  end

  defp record_upload_failure_file(nil, auth, file_id, request_opts, status, code, _now) do
    record_file_request_or_rollback(auth, "failed", status, request_opts, %{
      "file" => %{"id" => file_id},
      "operation" => "create",
      "error_code" => to_string(code)
    })
  end

  defp record_upload_failure_file(file, auth, file_id, request_opts, status, code, now) do
    _file = FileState.fail_finalize!(file, now)

    record_file_request_or_rollback(auth, "failed", status, request_opts, %{
      "file" => %{"id" => file_id},
      "operation" => "create",
      "error_code" => to_string(code)
    })
  end

  defp record_finalize_success_or_incomplete(
         auth,
         file,
         file_id,
         request_opts,
         bridge_result,
         now,
         body
       ) do
    body
    |> finalize_body_state()
    |> record_finalize_body_state(auth, file, file_id, request_opts, bridge_result, now, body)
  end

  defp record_finalize_retry_timeout(auth, file, file_id, request_opts, bridge_result, body) do
    with {:ok, request} <-
           record_file_request_or_rollback(auth, "failed", 200, request_opts, %{
             "file" => %{"id" => file_id},
             "operation" => "uploaded",
             "upstream_status" => "retry"
           }),
         {:ok, request} <- merge_bridge_route_metadata_or_rollback(request, bridge_result) do
      {:ok, %{file: file, request: request, body: body}}
    end
  end

  defp record_finalize_bridge_error(
         auth,
         file,
         file_id,
         request_opts,
         bridge_error,
         status,
         now
       ) do
    _file = FileState.fail_finalize!(file, now)

    with {:ok, _request} <-
           record_file_request_or_rollback(
             auth,
             "failed",
             status,
             request_opts,
             %{
               "file" => %{"id" => file_id},
               "operation" => "uploaded",
               "error_code" => to_string(bridge_error.code)
             }
             |> Map.merge(RequestLog.bridge_route_metadata(bridge_error))
           ) do
      {:error, Map.drop(bridge_error, [:upstream])}
    end
  end

  defp record_finalize_body_state(
         :success,
         auth,
         file,
         file_id,
         request_opts,
         bridge_result,
         now,
         body
       ) do
    record_finalize_success(auth, file, file_id, request_opts, bridge_result, now, body)
  end

  defp record_finalize_body_state(
         :incomplete,
         auth,
         file,
         file_id,
         request_opts,
         _bridge_result,
         now,
         _body
       ) do
    record_finalize_incomplete(auth, file, file_id, request_opts, now)
  end

  defp record_finalize_success(auth, file, file_id, request_opts, bridge_result, now, body) do
    file = FileState.complete_upload!(file, now)

    with {:ok, request} <-
           record_file_request_or_rollback(auth, "succeeded", 200, request_opts, %{
             "file" => %{"id" => file_id},
             "operation" => "uploaded",
             "upstream_status" => Map.get(body, "status")
           }),
         {:ok, request} <- merge_bridge_route_metadata_or_rollback(request, bridge_result) do
      {:ok, %{file: file, request: request, body: body}}
    end
  end

  defp record_finalize_incomplete(auth, file, file_id, request_opts, now) do
    _file = FileState.fail_finalize!(file, now)

    with {:ok, _request} <-
           record_file_request_or_rollback(auth, "failed", 502, request_opts, %{
             "file" => %{"id" => file_id},
             "operation" => "uploaded",
             "error_code" => "upstream_file_finalize_incomplete"
           }) do
      {:error,
       error(
         502,
         :upstream_file_finalize_incomplete,
         "upstream file finalize did not return required data"
       )}
    end
  end

  defp finalize_success_body?(%{"status" => status, "download_url" => download_url})
       when is_binary(status) and is_binary(download_url) do
    String.downcase(status) in ["success", "uploaded", "completed"] and
      String.trim(download_url) != ""
  end

  defp finalize_success_body?(_body), do: false

  defp finalize_body_state(body) do
    if finalize_success_body?(body), do: :success, else: :incomplete
  end

  defp create_file_request_opts(opts), do: RequestMetadata.build(opts, "/backend-api/files")

  defp record_file_request_or_rollback(auth, status, response_status, request_opts, metadata) do
    case RequestLog.record_file_request(auth, status, response_status, request_opts, metadata) do
      {:ok, request} -> {:ok, request}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp merge_bridge_route_metadata_or_rollback(request, bridge_result) do
    case RequestLog.merge_bridge_route_metadata(request, bridge_result) do
      {:ok, request} -> {:ok, request}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp error(status, code, message, param \\ nil),
    do: %{status: status, code: code, message: message, param: param}

  defp now(%RequestMetadata{now: configured_now}) when not is_nil(configured_now),
    do: configured_now

  defp now(%RequestMetadata{}), do: now()
  defp now(opts) when is_list(opts), do: Keyword.get(opts, :now) || now()
  defp now(opts), do: Map.get(opts, :now) || now()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp unwrap_nested_transaction({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_nested_transaction({:ok, {:error, value}}), do: {:error, value}
  defp unwrap_nested_transaction({:error, value}), do: {:error, value}
end
