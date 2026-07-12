defmodule CodexPooler.Gateway.Routing.ModelMetadataTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Access.APIKeys.ReasoningEffortPolicy.MetadataProjection
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Routing.ModelMetadata

  test "normalizes unsupported capability terms without raising" do
    assert ModelMetadata.normalize_capability_value(%{mode: "audio"}) == ""
    assert ModelMetadata.normalize_capability_value(["image"]) == ""
  end

  test "reads supported compatibility metadata from atom keys" do
    assert ModelMetadata.input_modalities(%{input_modalities: [:text, "image"]}) == [
             "text",
             "image"
           ]

    assert ModelMetadata.supports_audio_transcription?(%{
             capabilities: %{audio_input: true, transcription: "enabled"}
           })

    assert ModelMetadata.metadata_map(%{capabilities: %{vision_input: true}}, "capabilities") ==
             %{vision_input: true}
  end

  test "codex model payload exposes comp_hash only for non-empty string metadata" do
    assert model_payload(%{"comp_hash" => " comp-fixture-hash "})["comp_hash"] ==
             "comp-fixture-hash"

    for metadata <- [
          %{},
          %{"comp_hash" => ""},
          %{"comp_hash" => "   "},
          %{"comp_hash" => 123},
          %{"comp_hash" => ["comp-fixture-hash"]},
          %{"comp_hash" => %{"value" => "comp-fixture-hash"}}
        ] do
      refute Map.has_key?(model_payload(metadata), "comp_hash")
    end
  end

  test "codex model payload preserves all advertised GPT-5.6 reasoning levels" do
    efforts = ~w(low medium high xhigh max ultra)

    payload =
      model_payload(%{
        "default_reasoning_level" => "low",
        "supported_reasoning_levels" => efforts
      })

    assert payload["default_reasoning_level"] == "low"

    assert payload["supported_reasoning_levels"] ==
             Enum.map(efforts, &%{"effort" => &1, "description" => &1})
  end

  test "codex model payload applies an optional reasoning metadata projection verbatim" do
    projection = %MetadataProjection{
      levels: [
        %{"effort" => "low", "description" => "Quick"},
        %{"effort" => "medium", "description" => "Balanced"}
      ],
      default_effort: "medium"
    }

    payload =
      %{"supported_reasoning_levels" => ~w(low medium high), "default_reasoning_level" => "high"}
      |> reasoning_model()
      |> ModelMetadata.codex_model_payload(%{}, projection)

    assert payload["supported_reasoning_levels"] == projection.levels
    assert payload["default_reasoning_level"] == "medium"
  end

  test "codex model payload keeps a reasoning model visible with an empty projection" do
    projection = %MetadataProjection{levels: [], default_effort: nil}

    payload =
      %{"supported_reasoning_levels" => ~w(low medium), "default_reasoning_level" => "medium"}
      |> reasoning_model()
      |> ModelMetadata.codex_model_payload(%{}, projection)

    assert payload["slug"] == "gpt-test-model"
    assert payload["supported_reasoning_levels"] == []
    assert is_nil(payload["default_reasoning_level"])
  end

  test "returns explicit or fallback reasoning levels with their default" do
    explicit =
      reasoning_model(%{
        "supported_reasoning_levels" => ["low", "high"],
        "default_reasoning_level" => "high"
      })

    fallback = reasoning_model(%{})

    assert ModelMetadata.reasoning_levels_and_default(explicit) == {~w(low high), "high"}

    assert ModelMetadata.reasoning_levels_and_default(fallback) ==
             {~w(low medium high xhigh), "medium"}
  end

  test "returns effective reasoning maps with descriptions and canonical semantics" do
    model =
      reasoning_model(%{
        "supported_reasoning_levels" => [
          %{"effort" => "medium", "description" => "Balanced"},
          %{"effort" => " HIGH ", "description" => "Deep", "extra" => "preserved"},
          %{"effort" => "low", "description" => "Quick"}
        ],
        "default_reasoning_level" => " HIGH "
      })

    assert ModelMetadata.reasoning_level_maps_and_default(model) ==
             {[
                %{"effort" => "medium", "description" => "Balanced"},
                %{"effort" => "high", "description" => "Deep", "extra" => "preserved"},
                %{"effort" => "low", "description" => "Quick"}
              ], "high"}
  end

  defp model_payload(metadata) do
    metadata
    |> reasoning_model()
    |> ModelMetadata.codex_model_payload(%{})
  end

  defp reasoning_model(metadata) do
    %Model{
      upstream_model_id: "upstream-model",
      exposed_model_id: "gpt-test-model",
      display_name: "GPT Test Model",
      status: "active",
      supports_responses: true,
      supports_streaming: true,
      supports_tools: true,
      supports_reasoning: true,
      metadata: metadata
    }
  end
end
