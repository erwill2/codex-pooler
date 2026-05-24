defmodule CodexPoolerWeb.Admin.StaticGuardrailsTest do
  use ExUnit.Case, async: true

  @admin_source_files Path.wildcard("lib/codex_pooler_web/live/admin/**/*.ex")
  @forbidden_patterns [
    "@" <> "current_user",
    "Hero" <> "icons",
    "<" <> "script",
    "<" <> ".flash_group",
    ["System", ".unique_integer"] |> Enum.join(),
    ["Ecto", ".UUID.generate"] |> Enum.join(),
    ["UUID", ".uuid"] |> Enum.join(),
    [":", "rand."] |> Enum.join()
  ]

  test "admin source keeps shell guardrails recursively" do
    assert [_first_source_file | _remaining_source_files] = @admin_source_files

    violations =
      for source_file <- @admin_source_files,
          source = File.read!(source_file),
          pattern <- @forbidden_patterns,
          source =~ pattern do
        {source_file, pattern}
      end

    assert violations == []
  end
end
