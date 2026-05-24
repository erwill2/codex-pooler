defmodule Mix.Tasks.Pricing.ImportOpenaiTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Catalog
  alias Mix.Tasks.Pricing.ImportOpenai

  test "release-safe entrypoint uses the app priv path" do
    assert {:ok, result} = Catalog.import_openai_pricing_from_priv()
    assert result.source == "openai-json-pricing"
    assert result.total > 0
    assert result.inserted >= 0
  end

  test "missing file raises a controlled Mix error" do
    assert_raise Mix.Error,
                 ~r/pricing import failed for .*missing\.json.*file_read_failed/i,
                 fn ->
                   ImportOpenai.run(["priv/pricing/openai/missing.json"])
                 end
  end
end
