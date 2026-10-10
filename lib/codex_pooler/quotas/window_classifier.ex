defmodule CodexPooler.Quotas.WindowClassifier do
  @moduledoc """
  Pure quota-window descriptor classification over persisted raw evidence fields.

  The classifier returns semantic atoms for downstream presentation and routing code without
  persisting those descriptors or making usability decisions. Freshness, reset-bearing state,
  and exhaustion remain separate evidence predicates.
  """

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow

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

  # Fast-path pattern matches for canonical AccountQuotaWindow struct instances
  @spec classify(raw_window()) :: descriptor()
  def classify(%AccountQuotaWindow{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: "primary",
        window_minutes: @primary_5h_minutes
      }),
      do: :primary_5h

  def classify(%AccountQuotaWindow{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: "secondary",
        window_minutes: @weekly_minutes
      }),
      do: :weekly_secondary

  def classify(%AccountQuotaWindow{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: "primary",
        window_minutes: @monthly_minutes
      }),
      do: :monthly_primary

  def classify(%AccountQuotaWindow{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: "primary"
      }),
      do: :unknown_account_primary

  def classify(window) when is_map(window) do
    if account_window?(window) do
      case {kind(window), window_minutes(window)} do
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

  defp account_window?(window) do
    match_token?(field(window, :quota_key), @account_quota_key) and
      match_token?(field(window, :quota_scope), @account_scope) and
      match_token?(field(window, :quota_family), @account_family)
  end

  defp kind(window), do: token(field(window, :window_kind))

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

  defp match_token?(target, expected) when target == expected, do: true

  defp match_token?(value, expected) when is_binary(value) do
    value |> String.trim() |> String.downcase() == expected
  end

  defp match_token?(value, expected) when is_atom(value) and not is_nil(value) do
    value |> Atom.to_string() |> String.downcase() == expected
  end

  defp match_token?(_value, _expected), do: false

  defp token("primary"), do: "primary"
  defp token(:primary), do: "primary"
  defp token("secondary"), do: "secondary"
  defp token(:secondary), do: "secondary"

  defp token(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp token(value) when is_atom(value) and not is_nil(value) do
    value |> Atom.to_string() |> String.downcase()
  end

  defp token(_value), do: nil

  defp field(window, field_name) when is_map(window) do
    Map.get(window, field_name) || Map.get(window, Atom.to_string(field_name))
  end
end
