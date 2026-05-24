defmodule CodexPooler.Gateway.Payloads.ContinuityPayloadTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.ContinuityPayload
  alias CodexPooler.Gateway.Payloads.RequestOptions

  test "hydrates previous response id from payload only when continuity lacks one" do
    options = RequestOptions.build(%{}, "/backend-api/codex/responses", %{})

    hydrated =
      ContinuityPayload.put_previous_response_id(options, %{
        "previous_response_id" => " resp_payload "
      })

    assert hydrated.continuity.previous_response_id == "resp_payload"

    preserved =
      hydrated
      |> RequestOptions.put_continuity(previous_response_id: "resp_explicit")
      |> ContinuityPayload.put_previous_response_id(%{
        previous_response_id: "resp_payload_next"
      })

    assert preserved.continuity.previous_response_id == "resp_explicit"
  end
end
