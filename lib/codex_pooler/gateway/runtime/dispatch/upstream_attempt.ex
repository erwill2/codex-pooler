defmodule CodexPooler.Gateway.Runtime.Dispatch.UpstreamAttempt do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedContext
  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Streaming.StreamDispatch
  alias CodexPooler.Gateway.Runtime.Streaming.StreamLifecycle
  alias CodexPooler.Gateway.Transports.Streaming.WebSocketCodec
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

    dispatch_websocket_result(prepared_context, dispatch_request, callbacks, started)
  end

  defp dispatch_websocket_result(prepared_context, dispatch_request, callbacks, started) do
    context = prepared_context.context

    case dispatch_websocket_request_with_owner_recovery(prepared_context, dispatch_request) do
      {:error, %{reason: {:retryable_first_event, failure}} = response} ->
        handle_retryable_first_websocket_event(
          prepared_context,
          dispatch_request,
          callbacks,
          response,
          failure,
          started
        )

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

  defp handle_retryable_first_websocket_event(
         %PreparedContext{context: %{allow_retry?: true} = context} = prepared_context,
         dispatch_request,
         callbacks,
         response,
         failure,
         _started
       ) do
    response_context = retryable_websocket_response_context(context, response)

    with {:ok, _recorded_failure} <-
           Finalization.record_retryable_first_event_stream_failure(
             Map.get(response, :body, ""),
             failure,
             response_context,
             record_health?: false
           ),
         {:ok, retry_context} <- create_same_assignment_retry_context(context) do
      retry_prepared_context = %{prepared_context | context: retry_context}

      retry_dispatch_request =
        dispatch_request(retry_prepared_context,
          accounting_request: dispatch_request.accounting_request,
          writer: dispatch_request.writer
        )

      dispatch_websocket_result(
        retry_prepared_context,
        retry_dispatch_request,
        callbacks,
        System.monotonic_time(:millisecond)
      )
    end
  end

  defp handle_retryable_first_websocket_event(
         %PreparedContext{context: context},
         dispatch_request,
         _callbacks,
         response,
         failure,
         _started
       ) do
    deliver_retry_exhausted_websocket_failure(dispatch_request, response)

    response_context = retryable_websocket_response_context(context, response)

    Finalization.finalize_first_event_stream_failure(
      Map.get(response, :body, ""),
      failure,
      response_context
    )
  end

  defp create_same_assignment_retry_context(context) do
    case Accounting.create_attempt(context.reserved.request, context.assignment, %{
           response_metadata:
             Map.merge(context.request_options.routing.routing_attempt_metadata || %{}, %{
               "pool_upstream_assignment_id" => context.assignment.id,
               "upstream_identity_id" => context.identity.id
             })
         }) do
      {:ok, attempt} ->
        {:ok,
         %{
           context
           | attempt: attempt,
             started: System.monotonic_time(:millisecond),
             retry_count: (context.retry_count || 0) + 1,
             allow_retry?: false
         }}

      {:error, reason} ->
        FailureResponse.accounting_failure(
          :create_same_assignment_websocket_retry_attempt,
          context.reserved.request,
          context.attempt,
          reason
        )
    end
  end

  defp retryable_websocket_response_context(context, response) do
    %ResponseContext{
      context: context,
      response: %Req.Response{status: 200, headers: Map.get(response, :headers, [])}
    }
  end

  defp deliver_retry_exhausted_websocket_failure(
         %DispatchRequest{accounting_request: %{id: _request_id} = request, writer: writer},
         upstream_response
       )
       when is_function(writer, 1) do
    request.id
    |> WebSocketCodec.stream_messages(Map.get(upstream_response, :body, ""))
    |> Enum.each(writer)
  end

  defp deliver_retry_exhausted_websocket_failure(_dispatch_request, _upstream_response), do: :ok

  defp dispatch_websocket_request_with_owner_recovery(prepared_context, dispatch_request) do
    case UpstreamDispatch.websocket_request(dispatch_request) do
      {:error, %{body: "", reason: :owner_unavailable}} = error ->
        retry_owner_websocket_request(prepared_context, dispatch_request, error)

      result ->
        result
    end
  end

  defp retry_owner_websocket_request(prepared_context, dispatch_request, original_error) do
    request_options = prepared_context.context.request_options

    if owner_forwarded_websocket_request?(request_options) do
      case Gateway.recover_websocket_owner_response_options(request_options) do
        {:ok, recovered_options} ->
          recovered_context = %{prepared_context.context | request_options: recovered_options}
          recovered_prepared_context = %{prepared_context | context: recovered_context}

          recovered_prepared_context
          |> dispatch_request(
            accounting_request: dispatch_request.accounting_request,
            writer: dispatch_request.writer
          )
          |> UpstreamDispatch.websocket_request()

        {:error, _reason} ->
          original_error
      end
    else
      original_error
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

  defp owner_forwarded_websocket_request?(%{transport: transport}) do
    transport.websocket_owner_forwarding_enabled? == true and
      not is_nil(transport.websocket_owner_session) and
      is_binary(transport.websocket_owner_lease_token) and
      is_map(transport.websocket_owner_downstream)
  end

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
