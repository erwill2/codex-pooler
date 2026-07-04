defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.ReinviteLink do
  @moduledoc false

  use CodexPoolerWeb, :verified_routes

  alias CodexPoolerWeb.Admin.PoolInviteForm

  @spec path_for_account(map()) :: String.t() | nil
  def path_for_account(%{assignments: [assignment | _assignments]} = account) do
    path_for_action(%{available?: true}, field(assignment, :pool_id), email_candidates(account))
  end

  def path_for_account(_account), do: nil

  @spec path_for_cockpit(map()) :: String.t() | nil
  def path_for_cockpit(%{actions: %{reinvite: action}} = cockpit) do
    path_for_action(action, default_pool_id(cockpit), [])
  end

  def path_for_cockpit(_cockpit), do: nil

  @spec path_for_action(map(), String.t() | nil, [term()]) :: String.t() | nil
  def path_for_action(%{available?: true}, pool_id, candidates) when is_binary(pool_id) do
    pool_id = String.trim(pool_id)

    if pool_id == "" do
      nil
    else
      params = invite_params(pool_id, candidates)
      ~p"/admin/invites?#{params}"
    end
  end

  def path_for_action(_action, _pool_id, _candidates), do: nil

  defp default_pool_id(%{assignments: %{items: [assignment | _items]}}),
    do: field(assignment, :pool_id)

  defp default_pool_id(_cockpit), do: nil

  defp invite_params(pool_id, candidates) do
    params = %{"create" => "1", "pool_id" => pool_id}

    case invite_email(candidates, pool_id) do
      nil -> params
      invited_email -> Map.put(params, "invited_email", invited_email)
    end
  end

  defp invite_email(candidates, pool_id) do
    candidates
    |> Enum.map(&present_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&valid_invite_email?(&1, pool_id))
  end

  defp email_candidates(account) do
    [
      field(account.identity, :account_email),
      field(account.identity, :chatgpt_account_id),
      field(account, :label)
    ]
  end

  defp valid_invite_email?(candidate, pool_id) do
    %{"pool_id" => pool_id, "invited_email" => candidate, "send_email" => "false"}
    |> PoolInviteForm.changeset(%{id: pool_id})
    |> Map.fetch!(:valid?)
  end

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_map, _key), do: nil
end
