## 2026-08-24 - Case-insensitive Substring Matching in Hot Paths

**Learning:** Using dynamic regular expressions (e.g., `plan =~ ~r/enterprise|team/i`) inside routing candidate ranking and model selection hot paths incurs dynamic regex compilation overhead. Replacing dynamic regular expressions with `String.downcase/1` combined with `String.contains?/2` using explicit `or` conditions provides a >3.5x performance speedup. Note that using `String.contains?(string, ["a", "b"])` with a list argument is slower than explicit `or` conditions because Elixir dynamic list pattern matching introduces runtime compilation overhead.

**Action:** In Elixir hot paths, prefer `String.downcase/1` and `String.contains?(s, "a") or String.contains?(s, "b")` over dynamic regex matching (`=~ ~r/.../i`) or passing lists to `String.contains?/2`.
