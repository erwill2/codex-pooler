defmodule CodexPooler.Gateway.Routing.ModelMetadataTest do
  use ExUnit.Case, async: true

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
end
