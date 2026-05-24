defmodule CodexPooler.Gateway.Runtime.Dispatch.PreDispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1, strict_text_format_payload: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Repo

  @endpoint_path "/backend-api/codex/responses"

  test "prepare returns request options and routable candidates without reserving a request" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "prepare this route"
    }

    request_options =
      request_options(auth, payload,
        request_id: "pre-dispatch-success-#{System.unique_integer([:positive])}",
        accepted_turn_state: "pre-dispatch-session",
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)

    assert [{assignment, identity}] = prepared.candidates
    assert assignment.id == setup.assignment.id
    assert identity.id == setup.identity.id
    assert prepared.request_options.routing.requested_model == setup.model.exposed_model_id
    assert %CodexSession{} = prepared.request_options.continuity.codex_session
    assert Repo.all(Request) == []
  end

  test "prepare propagates strict schema failures before reservation" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload =
      strict_text_format_payload(%{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{"answer" => %{"type" => "string"}},
        "required" => []
      })

    request_options =
      request_options(auth, payload,
        request_id: "pre-dispatch-schema-#{System.unique_integer([:positive])}",
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    assert {:error,
            %{
              code: "invalid_json_schema",
              param: "text.format.schema.required"
            }} = PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)

    assert Repo.all(Request) == []
  end

  test "prepare rejects invalid strict function tools before reservation" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    sentinel = "STRICT_FUNCTION_SENTINEL_DO_NOT_LOG"

    payload =
      %{
        "model" => setup.model.exposed_model_id,
        "input" => "prepare this route",
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "lookup_fixture",
              "description" => sentinel,
              "strict" => true,
              "parameters" => %{
                "type" => "object",
                "additionalProperties" => false,
                "description" => sentinel,
                "properties" => %{
                  "ok" => %{"type" => "boolean", "description" => sentinel}
                },
                "required" => []
              }
            }
          }
        ]
      }

    request_options =
      request_options(auth, payload,
        request_id: "pre-dispatch-function-#{System.unique_integer([:positive])}",
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id
      )

    assert {:error,
            %{
              code: "invalid_function_parameters",
              param: "tools.0.function.parameters.required"
            }} = PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)

    assert Repo.all(Request) == []
  end

  test "prepare authorizes model policy from request options" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "deny this route"
    }

    request_options =
      RequestOptions.build(
        %{request_id: "pre-dispatch-policy-#{System.unique_integer([:positive])}"},
        @endpoint_path,
        payload
      )
      |> RequestOptions.put_routing(
        requested_model: setup.model.exposed_model_id,
        effective_model: setup.model.exposed_model_id,
        api_key_policy: %{
          allowed_model_identifiers: ["other-model"],
          enforced_model_identifier: nil,
          enforced_reasoning_effort: nil,
          enforced_service_tier: nil,
          metadata: %{}
        }
      )

    assert {:error,
            %{
              status: 403,
              code: "model_not_allowed",
              message: "api key is not allowed to use this model"
            }} = PreDispatch.prepare(auth, @endpoint_path, payload, request_options, setup.model)
  end

  defp request_options(auth, payload, attrs) do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    {routing_attrs, opts} =
      Keyword.split(attrs, [:requested_model, :effective_model])

    opts
    |> RequestOptions.build(@endpoint_path, payload)
    |> RequestOptions.put_routing(Keyword.put(routing_attrs, :api_key_policy, policy))
  end
end
