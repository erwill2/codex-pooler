defmodule CodexPooler.Catalog.JobWorkflow do
  @moduledoc false

  alias CodexPooler.Catalog
  alias CodexPooler.Events

  @type orchestration_result :: {:ok, map()} | {:error, term()}

  @spec sync_catalog(term(), term()) :: orchestration_result()
  def sync_catalog(pool_id, trigger_kind) when is_binary(pool_id) do
    result =
      pool_id
      |> Catalog.sync_pool_catalog(trigger_kind: trigger_kind)
      |> normalize_catalog_result()

    broadcast_job_result(pool_id, "catalog_sync", result)
    result
  end

  defp normalize_catalog_result({:error, _sync_run, reason}), do: {:error, reason}
  defp normalize_catalog_result(result), do: result

  defp broadcast_job_result(pool_id, worker, {:ok, _result}) do
    Events.broadcast_job_status(pool_id, "job_status_updated", %{
      id: worker,
      worker: worker,
      status: "succeeded"
    })
  end

  defp broadcast_job_result(pool_id, worker, {:error, reason}) do
    Events.broadcast_job_status(pool_id, "job_status_updated", %{
      id: worker,
      worker: worker,
      status: "failed",
      code: inspect(reason)
    })
  end
end
