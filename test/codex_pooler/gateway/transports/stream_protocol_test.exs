defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocolTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  describe "normalize_public_openai_responses_sse_data/2" do
    test "carries incomplete response stream state explicitly" do
      state = StreamProtocol.public_openai_responses_stream_state()

      terminal =
        [
          "event: response.completed\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_explicit_state",
              "output" => [
                %{
                  "content" => [
                    %{"type" => "output_text", "text" => "split terminal text"}
                  ]
                }
              ]
            }
          })
        ]
        |> IO.iodata_to_binary()

      assert {"", state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(terminal, state)

      assert {chunk, _state} =
               StreamProtocol.normalize_public_openai_responses_sse_data("\n\n", state)

      assert chunk =~ "event: response.created\n"
      assert chunk =~ "event: response.output_text.delta\n"
      assert chunk =~ "split terminal text"
      refute Process.get({:openai_responses_stream_state, "resp_explicit_state"})
    end
  end

  describe "wrapped websocket/direct JSON terminal error frames" do
    test "masks previous-response nested errors when status is present" do
      frame =
        Jason.encode!(%{
          "type" => "error",
          "status" => 400,
          "error" => %{
            "code" => "previous_response_not_found",
            "message" => "missing previous response",
            "param" => "previous_response_id"
          }
        })

      assert {:ok, failure} = StreamProtocol.terminal_failure(frame)
      assert failure.code == "stream_incomplete"
      assert failure.upstream_code == "previous_response_not_found"

      assert %{"type" => "response.failed", "error" => error, "response" => response} =
               frame
               |> StreamProtocol.canonicalize_codex_responses_json_message()
               |> Jason.decode!()

      assert error["code"] == "stream_incomplete"
      assert error["message"] == "upstream stream incomplete"
      assert response["error"]["code"] == "stream_incomplete"
    end

    test "masks previous-response nested errors when status_code replaces status" do
      frame =
        Jason.encode!(%{
          "type" => "error",
          "status_code" => 400,
          "error" => %{
            "code" => "previous_response_not_found",
            "message" => "missing previous response",
            "param" => "previous_response_id"
          }
        })

      assert {:ok, failure} = StreamProtocol.terminal_failure(frame)
      assert failure.code == "stream_incomplete"
      assert failure.upstream_code == "previous_response_not_found"

      assert %{"type" => "response.failed", "error" => error, "response" => response} =
               frame
               |> StreamProtocol.canonicalize_codex_responses_json_message()
               |> Jason.decode!()

      assert error["code"] == "stream_incomplete"
      assert error["message"] == "upstream stream incomplete"
      assert response["error"]["code"] == "stream_incomplete"
    end

    test "uses nested rate limit code from status_code wrapped errors" do
      frame =
        Jason.encode!(%{
          "type" => "error",
          "status_code" => 429,
          "error" => %{
            "code" => "rate_limit_exceeded",
            "message" => "rate limited"
          }
        })

      assert {:ok, failure} = StreamProtocol.terminal_failure(frame)
      assert failure.code == "rate_limit_exceeded"
      assert failure.upstream_code == "rate_limit_exceeded"

      assert %{"type" => "response.failed", "error" => error, "response" => response} =
               frame
               |> StreamProtocol.canonicalize_codex_responses_json_message()
               |> Jason.decode!()

      assert error["code"] == "rate_limit_exceeded"
      assert response["error"]["code"] == "rate_limit_exceeded"
    end

    test "classifies top-level status_code errors without nested error safely" do
      frame =
        Jason.encode!(%{
          "type" => "error",
          "status_code" => 500,
          "message" => "upstream failed"
        })

      assert {:ok, failure} = StreamProtocol.terminal_failure(frame)
      assert failure.code == "server_error"
      assert failure.upstream_code == "server_error"

      assert %{"type" => "response.failed", "error" => error, "response" => response} =
               frame
               |> StreamProtocol.canonicalize_codex_responses_json_message()
               |> Jason.decode!()

      assert error["code"] == "server_error"
      assert error["message"] == "upstream failed"
      assert response["error"]["code"] == "server_error"
    end

    test "uses nested server_error code when status is absent" do
      frame =
        Jason.encode!(%{
          "type" => "error",
          "error" => %{
            "code" => "server_error",
            "message" => "failed"
          }
        })

      assert {:ok, failure} = StreamProtocol.terminal_failure(frame)
      assert failure.code == "server_error"
      assert failure.upstream_code == "server_error"

      assert %{"type" => "response.failed", "error" => error, "response" => response} =
               frame
               |> StreamProtocol.canonicalize_codex_responses_json_message()
               |> Jason.decode!()

      assert error["code"] == "server_error"
      assert response["error"]["code"] == "server_error"
    end
  end
end
