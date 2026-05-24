defmodule CodexPooler.Accounting.ReservationPolicy do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting.{LedgerEntry, Metadata}
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Repo

  @entry_release "release"
  @entry_settlement "settlement"
  @amount_recorded "recorded"
  @usage_known "usage_known"

  @spec policy_for_update(term(), String.t() | nil) :: struct() | nil
  def policy_for_update(api_key, requested_model) do
    bindings =
      Repo.all(
        from b in APIKeyPolicyBinding,
          where: b.api_key_id == ^api_key.id and b.status == "active",
          lock: "FOR UPDATE"
      )

    effective_policy_from_bindings(bindings, requested_model)
  end

  @spec effective_model(Model.t(), String.t() | nil, map()) :: String.t() | nil
  def effective_model(%Model{} = model, requested_model, opts) do
    attr(opts, :effective_model) || model.exposed_model_id || requested_model
  end

  @spec enforce_reservation_limits(term(), struct() | nil, map(), DateTime.t()) ::
          :ok | {:error, Metadata.accounting_error()}
  def enforce_reservation_limits(_api_key, nil, _estimate, _timestamp), do: :ok

  def enforce_reservation_limits(api_key, policy, estimate, timestamp) do
    case enforce_request_token_limits(policy, estimate) do
      :ok -> enforce_window_reservation_limits(api_key, policy, estimate, timestamp)
      {:error, _reason} = error -> error
    end
  end

  defp effective_policy_from_bindings(bindings, requested_model) do
    key = String.downcase(String.trim(requested_model || ""))

    Enum.find(
      bindings,
      &(String.downcase(to_string(&1.model_identifier || "")) == key and
          &1.binding_scope == "model")
    ) ||
      Enum.find(bindings, &(&1.binding_scope == "default"))
  end

  defp enforce_window_reservation_limits(api_key, policy, estimate, timestamp) do
    minute_usage = ledger_window_usage(api_key.id, DateTime.add(timestamp, -60, :second))
    daily_usage = ledger_window_usage(api_key.id, beginning_of_day(timestamp))
    weekly_usage = ledger_window_usage(api_key.id, DateTime.add(timestamp, -7, :day))

    [
      {:max_requests_per_minute, policy.max_requests_per_minute,
       minute_usage.effective_request_count, 1, "request_count", "minute"},
      {:max_tokens_per_day, policy.max_tokens_per_day, daily_usage.effective_total_tokens,
       estimate.total_tokens, "total_tokens", "daily"},
      {:max_tokens_per_week, policy.max_tokens_per_week, weekly_usage.effective_total_tokens,
       estimate.total_tokens, "total_tokens", "weekly"}
    ]
    |> Enum.reduce_while(:ok, fn limit, :ok ->
      case enforce_window_limit(limit) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp ledger_window_usage(api_key_id, since) do
    entries =
      Repo.all(
        from e in LedgerEntry,
          where:
            e.api_key_id == ^api_key_id and e.amount_status == @amount_recorded and
              e.occurred_at >= ^since
      )

    Enum.reduce(
      entries,
      %{
        effective_request_count: 0,
        effective_total_tokens: 0,
        effective_cost_micros: Decimal.new(0)
      },
      fn entry, acc ->
        sign = if entry.entry_kind == @entry_release, do: -1, else: 1

        cost =
          if entry.entry_kind == @entry_settlement and entry.usage_status == @usage_known,
            do: entry.settled_cost_micros,
            else: entry.estimated_cost_micros

        %{
          effective_request_count:
            acc.effective_request_count + sign * (entry.request_count || 0),
          effective_total_tokens: acc.effective_total_tokens + sign * (entry.total_tokens || 0),
          effective_cost_micros:
            Decimal.add(
              acc.effective_cost_micros,
              Decimal.mult(cost || Decimal.new(0), Decimal.new(sign))
            )
        }
      end
    )
  end

  defp enforce_request_token_limits(policy, estimate) do
    cond do
      positive_limit_exceeded?(policy.max_input_tokens_per_request, estimate.input_tokens) ->
        {:error,
         policy_limit_error(
           "max_input_tokens_per_request",
           "input_tokens",
           "request",
           estimate.input_tokens,
           policy.max_input_tokens_per_request
         )}

      positive_limit_exceeded?(policy.max_output_tokens_per_request, estimate.output_tokens) ->
        {:error,
         policy_limit_error(
           "max_output_tokens_per_request",
           "output_tokens",
           "request",
           estimate.output_tokens,
           policy.max_output_tokens_per_request
         )}

      true ->
        :ok
    end
  end

  defp enforce_window_limit({_field, nil, _current, _delta, _metric, _window}), do: :ok

  defp enforce_window_limit({field, max_value, current, delta, metric, window}) do
    current = decimal_to_integer(current)
    delta = decimal_to_integer(delta)
    max_value = decimal_to_integer(max_value)

    if current + delta > max_value do
      {:error, policy_limit_error(field, metric, window, current + delta, max_value)}
    else
      :ok
    end
  end

  defp positive_limit_exceeded?(nil, _value), do: false

  defp positive_limit_exceeded?(limit, value),
    do: decimal_to_integer(value) > decimal_to_integer(limit)

  defp policy_limit_error(field, metric, window, attempted, max_value) do
    Metadata.accounting_error(
      :api_key_policy_limit_exceeded,
      "api key policy #{field} exceeded for #{metric} in #{window} window: attempted #{attempted}, max #{max_value}"
    )
  end

  defp attr(map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp decimal_to_integer(nil), do: 0

  defp decimal_to_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer()

  defp decimal_to_integer(value) when is_integer(value), do: value

  defp beginning_of_day(timestamp) do
    timestamp
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end
end
