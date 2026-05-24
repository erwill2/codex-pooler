defmodule CodexPooler.Accounting.FailureResponse do
  @moduledoc false

  require Logger

  alias CodexPooler.Accounting.{Attempt, Request}

  @type gateway_error :: %{
          required(:status) => pos_integer(),
          required(:code) => String.t(),
          required(:message) => String.t(),
          optional(atom()) => term()
        }

  @spec accounting_failure(atom(), Request.t() | term(), Attempt.t() | nil, term()) ::
          {:error, gateway_error()}
  def accounting_failure(operation, request, attempt, reason) do
    Logger.error([
      "gateway accounting finalization failed",
      " operation=#{operation}",
      " request_id=#{record_id(request) || "unknown"}",
      " attempt_id=#{record_id(attempt) || "unknown"}",
      " reason=#{safe_failure_reason(reason)}"
    ])

    {:error,
     %{
       status: 500,
       code: "gateway_accounting_failed",
       message: "gateway accounting finalization failed"
     }}
  end

  defp safe_failure_reason(%Ecto.Changeset{}), do: "changeset"
  defp safe_failure_reason(_reason), do: "unknown"

  defp record_id(%{id: id}) when is_binary(id), do: id
  defp record_id(_record), do: nil
end
