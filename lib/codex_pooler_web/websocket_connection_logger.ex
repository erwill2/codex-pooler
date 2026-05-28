defmodule CodexPoolerWeb.WebsocketConnectionLogger do
  @moduledoc false

  require Logger

  @init_failed_message "websocket init failed before request reservation"
  @closed_message "websocket closed before request reservation"

  @metadata_keys [
    :request_id,
    :endpoint,
    :transport,
    :route_class,
    :phase,
    :reason_class,
    :elapsed_ms,
    :codex_session_id,
    :owner_instance_id,
    :proxy_instance_id,
    :downstream_epoch
  ]

  @type event_metadata :: keyword() | map()

  @spec init_failed_message() :: String.t()
  def init_failed_message, do: @init_failed_message

  @spec closed_message() :: String.t()
  def closed_message, do: @closed_message

  @spec log_init_failed_before_request_reservation(event_metadata(), term()) :: :ok
  def log_init_failed_before_request_reservation(metadata, reason) do
    log_event(:warning, @init_failed_message, metadata, reason)
  end

  @spec log_closed_before_request_reservation(event_metadata(), term()) :: :ok
  def log_closed_before_request_reservation(metadata, reason) do
    log_event(:info, @closed_message, metadata, reason)
  end

  @spec reason_class(term()) :: String.t()
  def reason_class(:normal), do: "normal"
  def reason_class(:closed), do: "closed"
  def reason_class(:remote), do: "remote"
  def reason_class(:timeout), do: "timeout"
  def reason_class(:shutdown), do: "shutdown"
  def reason_class({:shutdown, _reason}), do: "shutdown"
  def reason_class({:error, reason}), do: reason_class(reason)
  def reason_class({:EXIT, _reason}), do: "exit"
  def reason_class({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  def reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_class(reason) when is_binary(reason), do: "binary_reason"
  def reason_class(reason) when is_integer(reason), do: "numeric_reason"
  def reason_class(%module{}) when is_atom(module), do: safe_log_value(inspect(module))
  def reason_class(_reason), do: "non_atom_reason"

  defp log_event(level, message, metadata, reason) do
    log_metadata =
      metadata
      |> normalize_metadata()
      |> Map.put(:reason_class, reason_class(reason))
      |> allowed_metadata()
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{safe_log_value(value)}" end)

    Logger.log(level, fn -> message <> metadata_suffix(log_metadata) end)

    :ok
  end

  defp metadata_suffix(""), do: ""
  defp metadata_suffix(metadata), do: " " <> metadata

  defp normalize_metadata(metadata) when is_list(metadata), do: Map.new(metadata)
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp allowed_metadata(metadata) do
    @metadata_keys
    |> Enum.reduce([], fn key, acc ->
      value = metadata_value(metadata, key)

      if is_nil(value) do
        acc
      else
        [{key, value} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp safe_log_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_log_value(value) when is_integer(value), do: Integer.to_string(value)

  defp safe_log_value(value) when is_binary(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9_.:-]+/, "_")
    |> String.slice(0, 120)
    |> case do
      "" -> "unknown"
      sanitized -> sanitized
    end
  end

  defp safe_log_value(_value), do: "unknown"
end
