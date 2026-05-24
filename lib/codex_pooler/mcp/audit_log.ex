defmodule CodexPooler.MCP.AuditLog do
  @moduledoc false

  alias CodexPooler.Accounts.User
  alias CodexPooler.Audit
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings}

  @type audit_result :: {:ok, term()} | {:error, term()} | term()

  @spec audit_operator_mcp_setting(audit_result(), User.t(), boolean()) :: audit_result()
  def audit_operator_mcp_setting(result, %User{} = operator, enabled) when is_boolean(enabled) do
    tap(result, fn
      {:ok, %OperatorMCPSettings{}} ->
        Audit.record_user_event(operator, %{
          action: operator_mcp_action(enabled),
          target_type: "user",
          target_id: operator.id,
          details: %{
            operator_id: operator.id,
            enabled: enabled
          }
        })

      _result ->
        :ok
    end)
  end

  @spec audit_operator_token_create(audit_result(), User.t()) :: audit_result()
  def audit_operator_token_create(result, %User{} = operator) do
    audit_operator_token_change(result, operator, "mcp.token_create")
  end

  @spec audit_operator_token_update(audit_result(), User.t(), OperatorMCPKey.t()) ::
          audit_result()
  def audit_operator_token_update(result, %User{} = operator, %OperatorMCPKey{} = previous_key) do
    audit_operator_token_change(result, operator, "mcp.token_update", fn key ->
      %{
        changed_fields: ["label"],
        previous_label: previous_key.label,
        label: key.label
      }
    end)
  end

  @spec audit_operator_token_delete(audit_result(), User.t()) :: audit_result()
  def audit_operator_token_delete(result, %User{} = operator) do
    audit_operator_token_change(result, operator, "mcp.token_delete")
  end

  defp audit_operator_token_change(result, operator, action, extra_details \\ fn _key -> %{} end) do
    tap(result, fn
      {:ok, resource} ->
        with %OperatorMCPKey{} = key <- operator_token_audit_resource(resource) do
          Audit.record_user_event(operator, %{
            action: action,
            target_type: "operator_mcp_key",
            target_id: key.id,
            details: Map.merge(operator_token_details(key), extra_details.(key))
          })
        end

      _result ->
        :ok
    end)
  end

  defp operator_token_audit_resource(%{key: %OperatorMCPKey{} = key}), do: key
  defp operator_token_audit_resource(%OperatorMCPKey{} = key), do: key
  defp operator_token_audit_resource(_resource), do: nil

  defp operator_token_details(%OperatorMCPKey{} = key) do
    %{
      operator_id: key.operator_id,
      label: key.label
    }
  end

  defp operator_mcp_action(true), do: "mcp.operator_enable"
  defp operator_mcp_action(false), do: "mcp.operator_disable"
end
