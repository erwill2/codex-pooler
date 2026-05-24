defmodule CodexPooler.Gateway.Runtime.Finalization.ResponseUsageTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage

  describe "from_json/1" do
    test "extracts flat usage from JSON responses" do
      body =
        Jason.encode!(%{
          "service_tier" => "priority",
          "usage" => %{
            "input_tokens" => 10,
            "input_tokens_details" => %{"cached_tokens" => 4},
            "output_tokens" => "7",
            "reasoning_tokens" => nil,
            "total_tokens" => 17
          }
        })

      assert ResponseUsage.from_json(body) == %{
               status: "usage_known",
               source: "upstream_usage",
               input_tokens: 10,
               cached_input_tokens: 4,
               output_tokens: 7,
               reasoning_tokens: 0,
               total_tokens: 17,
               service_tier: "priority"
             }
    end

    test "extracts nested response usage from output items" do
      body =
        Jason.encode!(%{
          "output" => [
            %{"type" => "message"},
            %{
              "response" => %{
                "service_tier" => "default",
                "usage" => %{
                  "prompt_tokens" => 2,
                  "prompt_tokens_details" => %{"cached_tokens" => 1},
                  "completion_tokens" => 3,
                  "total_tokens" => 5
                }
              }
            }
          ]
        })

      assert %{
               status: "usage_known",
               input_tokens: 2,
               cached_input_tokens: 1,
               output_tokens: 3,
               reasoning_tokens: 0,
               total_tokens: 5,
               service_tier: "default"
             } = ResponseUsage.from_json(body)
    end

    test "marks malformed JSON and invalid usage token values as unknown" do
      assert ResponseUsage.from_json("{") == %{
               status: "usage_unknown",
               source: "json_decode_failed"
             }

      body = Jason.encode!(%{"usage" => %{"input_tokens" => 1.2}})

      assert ResponseUsage.from_json(body) == %{
               status: "usage_unknown",
               source: "invalid_usage_tokens"
             }
    end
  end

  describe "from_sse/1" do
    test "extracts first valid usage payload from SSE data frames" do
      body = """
      event: ping
      data: nope

      event: response.completed
      data: {"response":{"service_tier":"flex","usage":{"input_tokens":3,"cached_input_tokens":2,"output_tokens":4,"total_tokens":7}}}

      data: [DONE]

      """

      assert %{
               status: "usage_known",
               input_tokens: 3,
               cached_input_tokens: 2,
               output_tokens: 4,
               reasoning_tokens: 0,
               total_tokens: 7,
               service_tier: "flex"
             } = ResponseUsage.from_sse(body)
    end

    test "marks SSE without usage as unknown" do
      body = ~S"""
      data: {"type":"response.created"}

      data: [DONE]

      """

      assert ResponseUsage.from_sse(body) ==
               %{status: "usage_unknown", source: "sse_usage_missing"}
    end
  end
end
