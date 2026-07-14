defmodule CodexPooler.Gateway.Runtime.Streaming.StreamAttempt do
  @moduledoc """
  Tracks and classifies the first SSE event for a streaming gateway attempt.
  """

  alias CodexPooler.Gateway.Runtime.ModelUnavailable
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @type classification ::
          {:retry, StreamProtocol.terminal_failure()}
          | {:write, binary()}
          | {:write_terminal_failure, binary(), StreamProtocol.terminal_failure()}
          | :buffered
  @type first_event_state :: %{
          required(:classified?) => boolean(),
          required(:buffer) => binary()
        }

  @spec first_event_state() :: first_event_state()
  def first_event_state, do: %{classified?: false, buffer: ""}

  @spec classify_first_event(binary(), first_event_state(), term() | nil) ::
          {classification(), first_event_state()}
  def classify_first_event(data, state, context \\ nil)

  def classify_first_event(data, %{classified?: classified?, buffer: buffer} = state, context)
      when is_binary(data) and is_binary(buffer) do
    if classified? do
      classify_data_after_first_event(data)
    else
      classify_data_before_first_event(data, state, context)
    end
  end

  @spec clear_first_event_state(term()) :: :ok
  def clear_first_event_state(_attempt), do: :ok

  defp classify_data_after_first_event(data) do
    classification =
      case StreamProtocol.terminal_outcome(data) do
        {:ok, %{kind: :failed, failure: failure}} -> {:write_terminal_failure, data, failure}
        _outcome -> {:write, data}
      end

    {classification, %{classified?: true, buffer: ""}}
  end

  defp classify_data_before_first_event(data, %{buffer: buffer}, context) do
    buffer = buffer <> data

    case StreamProtocol.first_complete_event(buffer) do
      {:ok, event} -> classify_complete_first_event(buffer, event, context)
      :incomplete -> classify_incomplete_first_event(buffer)
    end
  end

  defp classify_incomplete_first_event(buffer) do
    if StreamProtocol.oversized_incomplete_sse_block?(buffer) do
      BufferTelemetry.record_oversized_incomplete(
        "first_event",
        byte_size(buffer),
        StreamProtocol.max_incomplete_sse_block_bytes()
      )

      {{:write, buffer}, %{classified?: true, buffer: ""}}
    else
      {:buffered, %{classified?: false, buffer: buffer}}
    end
  end

  defp classify_complete_first_event(buffer, event, context) do
    classification =
      case StreamProtocol.retryable_first_terminal_failure(event) do
        {:ok, failure} ->
          {:retry, failure}

        :error ->
          classify_model_unavailable_or_terminal(buffer, event, context)
      end

    {classification, classify_complete_first_event_state(event)}
  end

  defp classify_model_unavailable_or_terminal(buffer, event, context) do
    case StreamProtocol.terminal_failure_event(event) do
      {:ok, failure} ->
        if ModelUnavailable.retryable_failure?(failure, context),
          do: {:retry, failure},
          else: classify_non_retryable_first_event(buffer, event)

      _not_terminal ->
        classify_non_retryable_first_event(buffer, event)
    end
  end

  defp classify_non_retryable_first_event(buffer, event) do
    if StreamProtocol.internal_rate_limit_event?(event) do
      {:write, buffer}
    else
      case StreamProtocol.terminal_outcome_event(event) do
        {:ok, %{kind: :failed, failure: failure}} -> {:write_terminal_failure, buffer, failure}
        _outcome -> {:write, buffer}
      end
    end
  end

  defp classify_complete_first_event_state(event) do
    if StreamProtocol.internal_rate_limit_event?(event) do
      %{classified?: false, buffer: ""}
    else
      %{classified?: true, buffer: ""}
    end
  end
end
