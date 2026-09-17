## 2026-03-30 - String.downcase + String.contains vs Dynamic Regex Matching
**Learning:** In Elixir, using `String.downcase/1` and `String.contains?/2` with explicit `or` conditions for case-insensitive multi-substring checks in hot paths is significantly faster (~5.9x speedup) than dynamic regex evaluation using `=~ ~r/.../i`.
**Action:** Replace `string =~ ~r/sub1|sub2/i` pattern matches with `String.contains?(String.downcase(string), "sub1") or String.contains?(String.downcase(string), "sub2")` when ranking or filtering records in routing or catalog selection paths.
