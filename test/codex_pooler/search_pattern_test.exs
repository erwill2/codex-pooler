defmodule CodexPooler.SearchPatternTest do
  use ExUnit.Case, async: true

  alias CodexPooler.SearchPattern

  test "escapes LIKE wildcards and backslashes while keeping substring matching" do
    assert SearchPattern.contains("ab%_\\cd") == "%ab\\%\\_\\\\cd%"
    assert SearchPattern.contains("hello") == "%hello%"
  end
end
