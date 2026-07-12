defmodule CodexPooler.Gateway.DenialsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Repo

  @endpoint_path "/backend-api/codex/responses"

  test "gateway denial persists only allowlisted reasoning policy metadata" do
    fake = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(fake)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = %{"model" => setup.model.exposed_model_id, "input" => "synthetic"}
    opts = RequestOptions.build(%{}, @endpoint_path, payload)

    reason = %{
      status: 400,
      code: "reasoning_effort_not_allowed",
      message: "reasoning effort is not available for this API key",
      param: "reasoning.effort",
      reasoning_policy: %{
        policy_mode: "allow_up_to",
        configured_effort: "low",
        requested_effort: "high",
        applied_effort: nil,
        unsafe: "discarded"
      }
    }

    assert {:error, ^reason} =
             Denials.log_gateway(%Denials.Context{
               auth: auth,
               model: setup.model,
               reason: reason,
               endpoint: @endpoint_path,
               payload: payload,
               opts: opts
             })

    assert [request] = Repo.all(Request)
    assert Repo.all(Attempt) == []
    assert FakeUpstream.count(fake) == 0

    assert request.request_metadata["gateway_denial"] == %{
             "code" => "reasoning_effort_not_allowed",
             "message" => "reasoning effort is not available for this API key",
             "param" => "reasoning.effort",
             "reasoning_policy" => %{
               "policy_mode" => "allow_up_to",
               "configured_effort" => "low",
               "requested_effort" => "high",
               "applied_effort" => nil
             }
           }
  end

  test "gateway denial classifies unknown requested reasoning without persisting raw text" do
    fake = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(fake)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    raw_effort = String.duplicate("x", 4_096)
    payload = %{"model" => setup.model.exposed_model_id, "reasoning" => %{"effort" => raw_effort}}
    opts = RequestOptions.build(%{}, @endpoint_path, payload)

    reason = %{
      status: 400,
      code: "reasoning_effort_not_allowed",
      message: "reasoning effort is not available for this API key",
      param: "reasoning.effort",
      reasoning_policy: %{
        policy_mode: "allow_up_to",
        configured_effort: "low",
        requested_effort: raw_effort,
        applied_effort: nil
      }
    }

    assert {:error, ^reason} =
             Denials.log_gateway(%Denials.Context{
               auth: auth,
               model: setup.model,
               reason: reason,
               endpoint: @endpoint_path,
               payload: payload,
               opts: opts
             })

    assert [request] = Repo.all(Request)

    assert request.request_metadata["gateway_denial"]["reasoning_policy"][
             "requested_effort"
           ] == "unknown"

    refute inspect(request.request_metadata) =~ raw_effort
  end
end
