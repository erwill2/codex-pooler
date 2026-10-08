defmodule CodexPooler.Quotas.WindowClassifier do
  @moduledoc """
  Pure quota-window descriptor classification over persisted raw evidence fields.

  The classifier returns semantic atoms for downstream presentation and routing code without
  persisting those descriptors or making usability decisions. Freshness, reset-bearing state,
  and exhaustion remain separate evidence predicates.
  """

  @account_quota_key "account"
  @account_scope "account"
  @account_family "account"
  @primary_kind "primary"
  @secondary_kind "secondary"
  @primary_5h_minutes 300
  @weekly_minutes 10_080
  @monthly_minutes 43_200

  @type descriptor ::
          :primary_5h
          | :weekly_secondary
          | :monthly_primary
          | :unknown_account_primary
          | :unknown

  @type raw_window :: struct() | %{optional(atom() | String.t()) => term()}

  @spec classify(raw_window()) :: descriptor()
  def classify(window) when is_map(window) do
    # Single-pass attribute extraction to eliminate redundant map lookups and string normalizations
    if token(window, :quota_key) == @account_quota_key and
         token(window, :quota_scope) == @account_scope and
         token(window, :quota_family) == @account_family do
      case {token(window, :window_kind), window_minutes(window)} do
        {@primary_kind, @primary_5h_minutes} -> :primary_5h
        {@secondary_kind, @weekly_minutes} -> :weekly_secondary
        {@primary_kind, @monthly_minutes} -> :monthly_primary
        {@primary_kind, _minutes} -> :unknown_account_primary
        _other -> :unknown
      end
    else
      :unknown
    end
  end

  def classify(_window), do: :unknown

  @spec primary_5h?(raw_window()) :: boolean()
  def primary_5h?(window), do: classify(window) == :primary_5h

  @spec weekly_secondary?(raw_window()) :: boolean()
  def weekly_secondary?(window), do: classify(window) == :weekly_secondary

  @spec monthly_primary?(raw_window()) :: boolean()
  def monthly_primary?(window), do: classify(window) == :monthly_primary

  @spec saved_reset_window?(raw_window()) :: boolean()
  def saved_reset_window?(window),
    do: classify(window) in [:weekly_secondary, :monthly_primary]

  @spec unknown_account_primary?(raw_window()) :: boolean()
  def unknown_account_primary?(window), do: classify(window) == :unknown_account_primary

  defp window_minutes(window) do
    case field(window, :window_minutes) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {minutes, ""} -> minutes
          _invalid -> nil
        end

      _value ->
        nil
    end
  end

  defp token(window, field_name) do
    case field(window, field_name) do
      value when is_binary(value) ->
        value |> String.trim() |> String.downcase()

      value when is_atom(value) and not is_nil(value) ->
        value |> Atom.to_string() |> String.downcase()

      _value ->
        nil
    end
  end

  defp field(window, field_name) when is_map(window) do
    Map.get(window, field_name) || Map.get(window, Atom.to_string(field_name))
  end
end
