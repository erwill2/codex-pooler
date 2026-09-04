## 2026-07-18 - Case-insensitive Plan Substring Matching in Hot Paths
**Learning:** Using dynamic regular expressions (`=~ ~r/.../i`) in Elixir functions evaluated on every routing or catalog sorting pass incurs significant execution overhead due to regex engine execution. Converting strings with `String.downcase/1` and checking substrings via `String.contains?/2` with explicit `or` logic is over 5.5x faster.
**Action:** Replace dynamic regex substring checks in candidate routing and read-model plan ranking hot paths with `String.downcase/1` and `String.contains?/2`.
