defmodule CodexPooler.SearchPatternTest do
  use ExUnit.Case, async: true

  alias CodexPooler.SearchPattern

  test "escapes LIKE wildcards and backslashes while keeping substring matching" do
    assert SearchPattern.contains("ab%_\\cd") == "%ab\\%\\_\\\\cd%"
    assert SearchPattern.contains("hello") == "%hello%"
    assert SearchPattern.contains("") == "%%"
  end

  test "handles nil and non-binary inputs safely" do
    assert SearchPattern.contains(nil) == "%%"
    assert SearchPattern.contains(123) == "%123%"
    assert SearchPattern.contains(:test) == "%test%"
  end
end
