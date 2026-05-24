defmodule CodexPooler.Gateway.Runtime.Dispatch.UpstreamAttempt do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Streaming.StreamDispatch
  alias CodexPooler.Gateway.Runtime.Streaming.StreamLifecycle
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.UpstreamDispatch.Request, as: DispatchRequest
  alias CodexPooler.RouteClass

  @type callbacks :: %{
          required(:register_continuity) => (term(), term(), term() -> term()),
          required(:retry_dispatch) => (PreparedContext.t() -> dispatch_result())
        }
  @type dispatch_result :: CodexPooler.Gateway.Runtime.Dispatch.dispatch_result()

  @spec dispatch(PreparedContext.t(), callbacks()) :: dispatch_result()
  def dispatch(%PreparedContext{context: context} = prepared_context, callbacks) do
    if websocket_upstream?(context.payload, context.request_options.transport) do
      dispatch_websocket(prepared_context, callbacks)
    else
      dispatch_http(prepared_context, callbacks)
    end
  end

  defp dispatch_http(%PreparedContext{context: context} = prepared_context, callbacks) do
    dispatch_request = dispatch_request(prepared_context)

    case UpstreamDispatch.http_request(dispatch_request) do
      {:ok, response} ->
        Finalization.handle_http_response(
          response,
          context,
          finalization_callbacks(callbacks)
        )

      {:error, reason} ->
        Finalization.handle_dispatch_error(reason, context, elapsed_ms(context.started))
    end
  end

  defp dispatch_websocket(%PreparedContext{context: context} = prepared_context, callbacks) do
    started = System.monotonic_time(:millisecond)
    writer = context.request_options.transport.websocket_writer

    dispatch_request =
      dispatch_request(prepared_context,
        accounting_request: context.reserved.request,
        writer: writer
      )

    case UpstreamDispatch.websocket_request(dispatch_request) do
      {:ok, %{terminal: "response.completed"} = response} ->
        Finalization.finalize_completed_websocket_response(
          context,
          response
          |> Map.put(:started, started)
          |> Map.put(:callbacks, finalization_callbacks(callbacks))
        )

      {:ok, response} ->
        Finalization.finalize_terminal_websocket_response(
          context,
          Map.put(response, :started, started)
        )

      {:error, response} ->
        Finalization.finalize_failed_websocket_response(
          context,
          Map.put(response, :started, started)
        )
    end
  end

  defp finalization_callbacks(callbacks) do
    %{
      register_continuity: Map.fetch!(callbacks, :register_continuity),
      stream_result: fn response, context ->
        StreamDispatch.streaming_result(response, context, %{
          finalization_callbacks: finalization_callbacks(callbacks),
          http_first_event_retry:
            StreamLifecycle.http_first_event_retry(Map.fetch!(callbacks, :retry_dispatch))
        })
      end
    }
  end

  defp dispatch_request(%PreparedContext{context: context} = prepared_context, opts \\ []) do
    %DispatchRequest{
      url: prepared_context.url,
      token: prepared_context.token,
      upstream_payload: prepared_context.upstream_payload,
      original_payload: context.payload,
      identity: context.identity,
      accounting_request: Keyword.get(opts, :accounting_request),
      writer: Keyword.get(opts, :writer),
      request_options: context.request_options
    }
  end

  defp websocket_upstream?(payload, opts) do
    opts.transport == "websocket" and RouteClass.streaming?(payload) and
      is_function(opts.websocket_writer, 1)
  end

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
