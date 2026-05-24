defmodule CodexPooler.Gateway.OpenAICompatibility.ChatCompletionsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.ChatCompletions

  describe "normalize_stream_data/2" do
    test "carries split stream parser state explicitly" do
      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})

      split_event =
        [
          "event: response.output_text.delta\n",
          "data: ",
          Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "split answer"})
        ]
        |> IO.iodata_to_binary()

      assert {"", state} = ChatCompletions.normalize_stream_data(split_event, state)
      assert {chunk, _state} = ChatCompletions.normalize_stream_data("\n\n", state)

      assert chunk =~ "\"object\":\"chat.completion.chunk\""
      assert chunk =~ "\"role\":\"assistant\""
      assert chunk =~ "\"content\":\"split answer\""
      refute Process.get({:openai_chat_completions_stream_state, "gpt-example"})
    end
  end
end
