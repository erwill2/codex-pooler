defmodule CodexPooler.Gateway.Transports.Streaming.FunctionCallArguments do
  @moduledoc false

  @spec normalize_delta(binary(), binary()) :: {binary(), binary()}
  def normalize_delta(previous, "") when is_binary(previous), do: {"", previous}

  def normalize_delta("", incoming) when is_binary(incoming), do: {incoming, incoming}

  def normalize_delta(previous, incoming)
      when is_binary(previous) and is_binary(incoming) do
    if String.starts_with?(incoming, previous) do
      delta =
        binary_part(incoming, byte_size(previous), byte_size(incoming) - byte_size(previous))

      {delta, incoming}
    else
      {incoming, previous <> incoming}
    end
  end

  @spec reconcile_snapshot(binary(), binary()) :: {binary(), binary()}
  def reconcile_snapshot(previous, snapshot)
      when is_binary(previous) and is_binary(snapshot) do
    cond do
      snapshot == "" or snapshot == previous ->
        {"", previous}

      String.starts_with?(snapshot, previous) ->
        delta =
          binary_part(snapshot, byte_size(previous), byte_size(snapshot) - byte_size(previous))

        {delta, snapshot}

      true ->
        {"", previous}
    end
  end
end
