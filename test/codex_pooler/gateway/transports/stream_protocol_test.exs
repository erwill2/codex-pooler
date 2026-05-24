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
end
