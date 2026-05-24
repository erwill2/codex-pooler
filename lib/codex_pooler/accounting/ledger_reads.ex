defmodule CodexPooler.Accounting.LedgerReads do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Repo

  @spec latest_success_by_assignment_ids([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => DateTime.t() | nil
        }
  def latest_success_by_assignment_ids(assignment_ids) when is_list(assignment_ids) do
    assignment_ids =
      assignment_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Repo.all(
      from attempt in Attempt,
        where:
          attempt.pool_upstream_assignment_id in ^assignment_ids and attempt.status == "succeeded",
        group_by: attempt.pool_upstream_assignment_id,
        select: {attempt.pool_upstream_assignment_id, max(attempt.completed_at)}
    )
    |> Map.new()
  end

  @spec list_ledger_entries_for_request(Request.t() | Ecto.UUID.t()) :: [LedgerEntry.t()]
  def list_ledger_entries_for_request(%Request{id: request_id}),
    do: list_ledger_entries_for_request(request_id)

  def list_ledger_entries_for_request(request_id) when is_binary(request_id) do
    Repo.all(
      from entry in LedgerEntry,
        where: entry.request_id == ^request_id,
        order_by: [asc: entry.occurred_at, asc: entry.created_at]
    )
  end
end
