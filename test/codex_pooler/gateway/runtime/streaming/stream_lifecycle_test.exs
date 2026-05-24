defmodule CodexPooler.Gateway.Runtime.Streaming.StreamLifecycleTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [stream_retry_setup: 2]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch.{Context, ResponseContext}
  alias CodexPooler.Gateway.Runtime.Streaming.OpenAIStreamCollector
  alias CodexPooler.Gateway.Runtime.Streaming.StreamLifecycle

  @endpoint_path "/backend-api/codex/responses"

  test "OpenAI stream collection propagates first-event finalization failures" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_sse",
               correlation_id: "openai-stream-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    context = retry_context(setup, auth, request_options, invalid_request(reserved.request.id))
    response_context = %ResponseContext{context: context, response: %Req.Response{status: 200}}
    handler = OpenAIStreamCollector.first_event_retry_handler(response_context)

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} =
                 handler.(%{relay: :state}, "", %{
                   code: "server_error",
                   event_type: "response.failed",
                   upstream_code: nil
                 })
      end)

    assert log =~ "operation=merge_route_failure_metadata"
    refute log =~ "operation=merge_route_selection_metadata"
  end

  test "first-event retry stops when retryable failure settlement fails" do
    {setup, _first_upstream, _second_upstream} =
      stream_retry_setup(
        FakeUpstream.sse_stream([]),
        FakeUpstream.sse_stream([])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_sse",
               correlation_id: "stream-lifecycle-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    context = retry_context(setup, auth, request_options, invalid_request(reserved.request.id))
    response_context = %ResponseContext{context: context, response: %Req.Response{status: 200}}
    parent = self()

    handler =
      StreamLifecycle.first_event_retry_handler(
        response_context,
        fn _context ->
          send(parent, :retry_dispatch_called)
          {:ok, %{status: 200}}
        end,
        reset_state: & &1,
        stream_candidate: fn result, state ->
          send(parent, {:stream_candidate_called, result, state})
          {:ok, state}
        end
      )

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} =
                 handler.(%{relay: :state}, "", %{
                   code: "server_error",
                   event_type: "response.failed",
                   upstream_code: nil
                 })
      end)

    assert log =~ "operation=merge_route_failure_metadata"
    refute log =~ "operation=merge_route_selection_metadata"
    refute_received :retry_dispatch_called
    refute_received {:stream_candidate_called, _result, _state}
  end

  defp retry_context(setup, auth, request_options, request) do
    candidates = [
      {setup.assignment, setup.identity},
      {setup.fallback_assignment, setup.fallback_identity}
    ]

    %Context{
      auth: auth,
      endpoint: @endpoint_path,
      payload: payload(setup),
      model: setup.model,
      reserved: %{request: request},
      candidates: candidates,
      request_options: request_options,
      route_plan:
        BridgeRing.plan_route(
          auth,
          setup.model,
          candidates,
          RoutePlanInput.from_reserved(%{request: request}),
          request_options
        ),
      assignment: setup.assignment,
      identity: setup.identity,
      index: 0,
      retry_count: 0,
      allow_retry?: true,
      routing_attempt_metadata: %{},
      route_class: request_options.transport.route_class,
      started: System.monotonic_time(:millisecond)
    }
  end

  defp payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => "stream lifecycle accounting regression",
      "stream" => true
    }
  end

  defp request_options(auth, payload, setup) do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    %{
      request_id: "stream-lifecycle-#{System.unique_integer([:positive])}",
      upstream_endpoint: @endpoint_path
    }
    |> RequestOptions.build(@endpoint_path, payload)
    |> RequestOptions.put_routing(
      requested_model: setup.model.exposed_model_id,
      effective_model: setup.model.exposed_model_id,
      api_key_policy: policy
    )
  end

  defp invalid_request(id) do
    %{
      id: id,
      correlation_id: "stream-lifecycle-#{System.unique_integer([:positive])}"
    }
  end
end
