defmodule CodexPooler.Access.APIKeys.Notifications do
  @moduledoc false

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Events

  @spec notify_api_key_change(result, String.t()) :: result when result: term()
  def notify_api_key_change(result, reason), do: notify_api_key_change(result, reason, nil)

  @spec notify_api_key_change(result, String.t(), Ecto.UUID.t() | nil) :: result
        when result: term()
  def notify_api_key_change(
        {:ok, %{api_key: %APIKey{} = api_key}} = result,
        reason,
        previous_pool_id
      ) do
    broadcast_api_key_change(api_key, reason, previous_pool_id)
    result
  end

  def notify_api_key_change({:ok, %APIKey{} = api_key} = result, reason, previous_pool_id) do
    broadcast_api_key_change(api_key, reason, previous_pool_id)
    result
  end

  def notify_api_key_change(result, _reason, _previous_pool_id), do: result

  defp broadcast_api_key_change(%APIKey{} = api_key, reason, previous_pool_id) do
    [previous_pool_id, api_key.pool_id]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.each(fn pool_id ->
      Events.broadcast_pools(pool_id, reason, %{
        api_key_id: api_key.id,
        pool_id: api_key.pool_id,
        status: api_key.status
      })
    end)

    :ok
  end
end
