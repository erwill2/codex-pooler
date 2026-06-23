defmodule CodexPooler.Upstreams.SavedResets do
  @moduledoc """
  Metadata-only helpers for Codex saved reset observations and policy projection.
  """

  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @reported "reported"
  @unreported "unreported"
  @unavailable "unavailable"
  @usage_source "codex_usage_api"
  @reset_credits_source "codex_reset_credits_api"
  @codex_path_style "codex_api"
  @chatgpt_path_style "chatgpt_api"
  @unknown_path_style "unknown"
  @default_min_blocked_minutes 60
  @default_keep_credits 0
  @default_trigger_mode "blocked"
  @default_quota_threshold_percent 95

  @type count_parse_result :: {:reported, non_neg_integer()} | :unreported
  @type snapshot_projection :: %{
          required(:status) => String.t(),
          required(:available_count) => non_neg_integer() | nil,
          required(:reported?) => boolean(),
          required(:available?) => boolean(),
          required(:label) => String.t(),
          required(:source) => String.t() | nil,
          required(:path_style) => String.t() | nil,
          required(:usage_path) => String.t() | nil,
          required(:observed_at) => String.t() | nil,
          required(:available_expires_at) => [String.t()],
          required(:next_expires_at) => String.t() | nil,
          required(:expires_reported?) => boolean(),
          required(:in_progress?) => boolean(),
          required(:last_redemption) => map() | nil
        }
  @type auto_policy_projection :: %{
          required(:enabled?) => boolean(),
          required(:min_blocked_minutes) => non_neg_integer(),
          required(:keep_credits) => non_neg_integer(),
          required(:trigger_mode) => String.t(),
          required(:quota_threshold_percent) => 1..100
        }

  @spec count_from_usage_payload(term()) :: count_parse_result()
  def count_from_usage_payload(%{"rate_limit_reset_credits" => %{} = reset_credits}) do
    reset_credits
    |> Map.get("available_count")
    |> non_negative_truncated_integer()
    |> case do
      {:ok, count} -> {:reported, count}
      :error -> :unreported
    end
  end

  def count_from_usage_payload(_payload), do: :unreported

  @spec usage_snapshot(term(), DateTime.t(), String.t() | nil) :: map()
  def usage_snapshot(payload, %DateTime{} = observed_at, usage_url) do
    {usage_path, path_style} = usage_path_style(usage_url)

    case count_from_usage_payload(payload) do
      {:reported, count} ->
        %{
          "status" => @reported,
          "available_count" => count,
          "source" => @usage_source,
          "path_style" => path_style,
          "observed_at" => DateTime.to_iso8601(observed_at),
          "usage_path" => usage_path,
          "reason" => nil
        }
        |> Map.merge(expiration_metadata_from_payload(payload))

      :unreported ->
        %{
          "status" => @unreported,
          "available_count" => nil,
          "source" => @usage_source,
          "path_style" => path_style,
          "observed_at" => DateTime.to_iso8601(observed_at),
          "usage_path" => usage_path,
          "available_expires_at" => [],
          "next_expires_at" => nil,
          "reason" => %{"code" => "saved_resets_unreported"}
        }
    end
  end

  @spec credit_list_snapshot(term(), DateTime.t(), String.t() | nil) :: map()
  def credit_list_snapshot(payload, %DateTime{} = observed_at, usage_url) do
    {usage_path, path_style} = usage_path_style(usage_url)

    %{
      "status" => @reported,
      "available_count" => available_count_from_credit_list(payload),
      "source" => @reset_credits_source,
      "path_style" => path_style,
      "observed_at" => DateTime.to_iso8601(observed_at),
      "usage_path" => usage_path,
      "reason" => nil
    }
    |> Map.merge(expiration_metadata_from_payload(payload))
  end

  @spec unavailable_snapshot(DateTime.t(), String.t()) :: map()
  def unavailable_snapshot(%DateTime{} = observed_at, code) when is_binary(code) do
    %{
      "status" => @unavailable,
      "available_count" => nil,
      "source" => @reset_credits_source,
      "path_style" => @unknown_path_style,
      "observed_at" => DateTime.to_iso8601(observed_at),
      "usage_path" => nil,
      "available_expires_at" => [],
      "next_expires_at" => nil,
      "reason" => %{"code" => code}
    }
  end

  @spec snapshot(UpstreamIdentity.t() | map() | nil) :: snapshot_projection()
  def snapshot(%UpstreamIdentity{} = identity), do: snapshot(identity.metadata)

  def snapshot(%{} = metadata) do
    snapshot = Map.get(metadata, "saved_resets", metadata)
    redemption = Map.get(metadata, "saved_reset_redemption")
    status = snapshot_status(snapshot)
    available_count = snapshot_available_count(snapshot, status)
    available_expires_at = snapshot_available_expires_at(snapshot)
    next_expires_at = snapshot_next_expires_at(snapshot, available_expires_at)
    reported? = status == @reported
    available? = reported? and is_integer(available_count) and available_count > 0

    %{
      status: status,
      available_count: available_count,
      reported?: reported?,
      available?: available?,
      label: label(status, available_count),
      source: string_or_nil(snapshot["source"]),
      path_style: string_or_nil(snapshot["path_style"]),
      usage_path: string_or_nil(snapshot["usage_path"]),
      observed_at: string_or_nil(snapshot["observed_at"]),
      available_expires_at: available_expires_at,
      next_expires_at: next_expires_at,
      expires_reported?: next_expires_at != nil,
      in_progress?: redemption_in_progress?(redemption),
      last_redemption: redemption_or_nil(redemption)
    }
  end

  def snapshot(_identity_or_metadata) do
    snapshot(%{"saved_resets" => %{}})
  end

  @spec auto_policy(UpstreamIdentity.t()) :: auto_policy_projection()
  def auto_policy(%UpstreamIdentity{} = identity) do
    %{
      enabled?: identity.saved_reset_auto_redeem_enabled == true,
      min_blocked_minutes:
        non_negative_policy_value(
          identity.saved_reset_auto_redeem_min_blocked_minutes,
          @default_min_blocked_minutes
        ),
      keep_credits:
        non_negative_policy_value(
          identity.saved_reset_auto_redeem_keep_credits,
          @default_keep_credits
        ),
      trigger_mode: trigger_mode(identity.saved_reset_auto_redeem_trigger_mode),
      quota_threshold_percent:
        percent_policy_value(
          identity.saved_reset_auto_redeem_quota_threshold_percent,
          @default_quota_threshold_percent
        )
    }
  end

  defp usage_path_style(usage_url) when is_binary(usage_url) do
    case URI.parse(usage_url).path do
      path when path in ["/api/codex/usage", "/backend-api/codex/usage"] ->
        {path, @codex_path_style}

      path
      when path in [
             "/wham/usage",
             "/backend-api/wham/usage",
             "/wham/rate-limit-reset-credits",
             "/backend-api/wham/rate-limit-reset-credits"
           ] ->
        {chatgpt_usage_path(path), @chatgpt_path_style}

      _path ->
        {nil, @unknown_path_style}
    end
  end

  defp usage_path_style(_usage_url), do: {nil, @unknown_path_style}

  defp chatgpt_usage_path("/wham/rate-limit-reset-credits"), do: "/wham/usage"

  defp chatgpt_usage_path("/backend-api/wham/rate-limit-reset-credits"),
    do: "/backend-api/wham/usage"

  defp chatgpt_usage_path(path), do: path

  defp non_negative_truncated_integer(value) when is_integer(value), do: {:ok, max(value, 0)}

  defp non_negative_truncated_integer(value) when is_float(value) do
    {:ok, value |> trunc() |> max(0)}
  rescue
    _error -> :error
  end

  defp non_negative_truncated_integer(%Decimal{} = value) do
    {:ok, value |> Decimal.round(0, :down) |> Decimal.to_integer() |> max(0)}
  rescue
    _error -> :error
  end

  defp non_negative_truncated_integer(value) when is_binary(value) do
    value = String.trim(value)

    with false <- value == "",
         {decimal, ""} <- Decimal.parse(value) do
      non_negative_truncated_integer(decimal)
    else
      _invalid -> :error
    end
  rescue
    _error -> :error
  end

  defp non_negative_truncated_integer(_value), do: :error

  defp snapshot_status(%{"status" => @reported}), do: @reported
  defp snapshot_status(%{"status" => @unavailable}), do: @unavailable
  defp snapshot_status(%{"status" => @unreported}), do: @unreported
  defp snapshot_status(_snapshot), do: @unreported

  defp snapshot_available_count(%{"available_count" => count}, @reported) do
    case non_negative_truncated_integer(count) do
      {:ok, count} -> count
      :error -> nil
    end
  end

  defp snapshot_available_count(_snapshot, _status), do: nil

  defp snapshot_available_expires_at(%{"available_expires_at" => values}) when is_list(values) do
    values
    |> Enum.map(&safe_iso8601/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&datetime_sort_key/1)
  end

  defp snapshot_available_expires_at(_snapshot), do: []

  defp snapshot_next_expires_at(%{"next_expires_at" => value}, fallback_values) do
    safe_iso8601(value) || List.first(fallback_values)
  end

  defp snapshot_next_expires_at(_snapshot, fallback_values), do: List.first(fallback_values)

  defp expiration_metadata_from_payload(payload) do
    expires_at =
      payload
      |> credit_list_from_payload()
      |> available_expiration_iso8601s()

    %{
      "available_expires_at" => expires_at,
      "next_expires_at" => List.first(expires_at)
    }
  end

  defp available_count_from_credit_list(%{} = payload) do
    case non_negative_truncated_integer(Map.get(payload, "available_count")) do
      {:ok, count} -> count
      :error -> payload |> credit_list_from_payload() |> Enum.count(&available_credit?/1)
    end
  end

  defp available_count_from_credit_list(_payload), do: 0

  defp credit_list_from_payload(%{"rate_limit_reset_credits" => %{"credits" => credits}})
       when is_list(credits),
       do: credits

  defp credit_list_from_payload(%{"credits" => credits}) when is_list(credits), do: credits
  defp credit_list_from_payload(_payload), do: []

  defp available_expiration_iso8601s(credits) when is_list(credits) do
    credits
    |> Enum.filter(&available_credit?/1)
    |> Enum.map(fn credit -> safe_iso8601(credit["expires_at"]) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&datetime_sort_key/1)
  end

  defp available_credit?(%{"status" => status}) when is_binary(status), do: status == "available"
  defp available_credit?(%{}), do: true
  defp available_credit?(_credit), do: false

  defp safe_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _invalid -> nil
    end
  end

  defp safe_iso8601(_value), do: nil

  defp datetime_sort_key(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _invalid -> 0
    end
  end

  defp datetime_sort_key(_value), do: 0

  defp label(@reported, 1), do: "1 saved reset"
  defp label(@reported, count) when is_integer(count) and count > 1, do: "#{count} saved resets"
  defp label(@reported, _count), do: "No saved resets"
  defp label(@unavailable, _count), do: "Saved resets unavailable"
  defp label(_status, _count), do: "Saved resets not reported"

  defp redemption_in_progress?(%{"status" => "redeeming"}), do: true
  defp redemption_in_progress?(_redemption), do: false

  defp redemption_or_nil(%{} = redemption), do: redemption
  defp redemption_or_nil(_redemption), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp trigger_mode("threshold"), do: "threshold"
  defp trigger_mode(_mode), do: @default_trigger_mode

  defp percent_policy_value(value, _default)
       when is_integer(value) and value >= 1 and value <= 100,
       do: value

  defp percent_policy_value(_value, default), do: default

  defp non_negative_policy_value(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_policy_value(_value, default), do: default
end
