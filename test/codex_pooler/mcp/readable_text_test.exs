defmodule CodexPooler.MCP.ReadableTextTest do
  use ExUnit.Case, async: true

  alias CodexPooler.MCP.Redaction
  alias CodexPooler.MCP.Tools.ReadableText

  defmodule SampleStruct do
    defstruct [:id]
  end

  test "list formats bounded deterministic readable rows" do
    rows =
      for index <- 1..12 do
        %{
          "name" => "Sample #{index}",
          "status" => if(rem(index, 2) == 0, do: "active", else: "paused"),
          "count" => index
        }
      end

    text =
      ReadableText.list(
        "Pool metadata records",
        rows,
        [name: "name", status: "status", count: "count"],
        total: 12,
        offset: 5
      )

    assert String.starts_with?(text, "10 Pool metadata records returned; total 12; offset 5")
    assert text =~ "- name=Sample 1 status=paused count=1"
    assert text =~ "- name=Sample 10 status=active count=10"
    refute text =~ "Sample 11"
    assert text =~ "- ... 2 more rows omitted from text; use structuredContent or refine filters"
    refute text =~ "[%{"
  end

  test "list uses generic non-echoing empty text" do
    assert ReadableText.list("Pool metadata records", [], name: "name") ==
             "No Pool metadata records matched the visible scope"
  end

  test "required nil and blank display values become unknown while optional blanks are omitted" do
    text =
      ReadableText.detail("Operator metadata record", %{name: nil, status: "   ", note: ""}, [
        {:name, "name", required: true},
        {:status, "status", required: true},
        {:note, "note"}
      ])

    assert text ==
             "1 Operator metadata record returned\n- name=unknown status=unknown"
  end

  test "scalar values normalize newlines and cap visible length" do
    long = String.duplicate("a", 121)

    text =
      ReadableText.detail("Audit event", %{summary: "first\nsecond\tthird", long: long},
        summary: "summary",
        long: "long"
      )

    assert text =~ "summary=first second third"
    assert text =~ "long=#{String.duplicate("a", 120)}"
    refute text =~ String.duplicate("a", 121)
  end

  test "not found text never echoes caller selectors" do
    selector = "raw-selector-should-not-appear"
    text = ReadableText.not_found("Pool metadata record")

    assert text == "No visible Pool metadata record matched the selector"
    refute text =~ selector
  end

  test "ambiguity text uses sanitized candidates and count without caller selector" do
    selector = "private-selector-should-not-appear"

    text =
      ReadableText.ambiguous(
        "Pool metadata record",
        [
          %{"id" => "pool_123", "name" => "Sample A"},
          %{"id" => "pool_456", "name" => "Sample B"}
        ],
        id: "id",
        name: "name"
      )

    assert String.starts_with?(
             text,
             "2 visible Pool metadata record candidates matched the selector"
           )

    assert text =~ "- id=pool_123 name=Sample A"
    assert text =~ "- id=pool_456 name=Sample B"
    refute text =~ selector
  end

  test "raw structs are rejected as rows and nested row values" do
    assert_raise ArgumentError, ~r/sanitized maps/, fn ->
      ReadableText.list("records", [%SampleStruct{id: "raw"}], id: "id")
    end

    assert_raise ArgumentError, ~r/raw struct/, fn ->
      ReadableText.list("records", [%{"raw" => %SampleStruct{id: "raw"}}], raw: "raw")
    end
  end

  test "non-scalar display values are rejected instead of dumped" do
    assert_raise ArgumentError, ~r/sanitized scalars/, fn ->
      ReadableText.detail("record", %{"metadata" => %{"nested" => "value"}}, metadata: "metadata")
    end
  end

  test "defensive scalar cleaning redacts forbidden sentinels and unsafe raw shapes" do
    cases = [
      Redaction.forbidden_sentinel!(:prompt),
      "operator.privacy@example.com",
      "198.51.100.99",
      "https://files.example.com/private/path",
      "Bearer abcdefghijklmnopqrstuvwxyz123456",
      "sk_abcdefghijklmnopqrstuvwxyz1234567890",
      "eyJhbGciOiJIUzI1NiJ9.abcdefghijklmnopqrstuvwxyz.abcdefghijklmnopqrstuvwxyz"
    ]

    for unsafe <- cases do
      assert ReadableText.scalar(unsafe, required: true) == "[REDACTED]"
    end
  end

  test "formatted text passes MCP redaction safety checks" do
    text =
      ReadableText.list(
        "request log records",
        [%{"id" => "req_123", "client_ip" => "203.0.113.xxx", "operator" => "op***@example.com"}],
        [id: "id", client_ip: "client_ip", operator: "operator"],
        total: 1,
        offset: 0
      )

    assert :ok = Redaction.assert_text_content_safe!(text)

    assert :ok =
             Redaction.assert_mcp_output_safe!(%{
               structuredContent: %{
                 "items" => [
                   %{
                     "id" => "req_123",
                     "client_ip" => "203.0.113.xxx",
                     "operator_email" => "op***@example.com"
                   }
                 ]
               },
               content: [%{"type" => "text", "text" => text}]
             })
  end
end
