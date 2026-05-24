defmodule CodexPoolerWeb.Admin.RequestLogsDisplay.Errors do
  @moduledoc false

  def format_errors(%{errors: errors}) do
    if is_nil(errors) or errors == [] do
      ["—"]
    else
      error_display_items(errors)
    end
  end

  defp error_display_items(errors) do
    cond do
      Enum.any?(errors, &quota_exhaustion_error?/1) ->
        ["quota exhausted"] ++ reset_display_items(exhausted_reset_at(errors))

      Enum.any?(errors, &quota_evidence_unavailable?/1) ->
        ["quota evidence unavailable"]

      true ->
        errors
        |> Enum.map(&format_single_error/1)
        |> Enum.uniq()
    end
  end

  defp reset_display_items(nil), do: []
  defp reset_display_items(reset_at), do: ["resets #{format_reset_at(reset_at)}"]

  defp exhausted_reset_at(errors) do
    Enum.find_value(errors, fn error ->
      if quota_exhaustion_error?(error), do: error_reset_at(error)
    end)
  end

  defp quota_exhaustion_error?(%{code: code})
       when code in ["quota_exhausted", "quota_weekly_exhausted"],
       do: true

  defp quota_exhaustion_error?(%{"code" => code})
       when code in ["quota_exhausted", "quota_weekly_exhausted"],
       do: true

  defp quota_exhaustion_error?(%{reason_codes: reason_codes}) when is_list(reason_codes),
    do: "exhausted" in reason_codes

  defp quota_exhaustion_error?(%{"reason_codes" => reason_codes}) when is_list(reason_codes),
    do: "exhausted" in reason_codes

  defp quota_exhaustion_error?(_error), do: false

  defp quota_evidence_unavailable?(%{code: "quota_evidence_unavailable"}), do: true
  defp quota_evidence_unavailable?(%{"code" => "quota_evidence_unavailable"}), do: true
  defp quota_evidence_unavailable?(_error), do: false

  defp error_reset_at(%{reset_at: reset_at}), do: reset_at
  defp error_reset_at(%{"reset_at" => reset_at}), do: reset_at
  defp error_reset_at(_error), do: nil

  defp format_reset_at(%DateTime{} = reset_at),
    do: Calendar.strftime(reset_at, "%Y-%m-%d %H:%M UTC")

  defp format_reset_at(reset_at) when is_binary(reset_at) do
    case DateTime.from_iso8601(reset_at) do
      {:ok, datetime, _offset} -> format_reset_at(datetime)
      {:error, _reason} -> reset_at
    end
  end

  defp format_reset_at(reset_at), do: to_string(reset_at)

  defp format_single_error(%{code: code}) when is_binary(code) and code != "",
    do: code

  defp format_single_error(%{"code" => code}) when is_binary(code) and code != "",
    do: code

  defp format_single_error(%{source: source, kind: kind})
       when is_binary(source) and is_binary(kind),
       do: "#{source}:#{kind}"

  defp format_single_error(%{"source" => source, "kind" => kind})
       when is_binary(source) and is_binary(kind),
       do: "#{source}:#{kind}"

  defp format_single_error(%{}), do: "error"
  defp format_single_error(_other), do: "error"
end
