## 2026-07-19 - Fast Case-Insensitive Plan Matching
**Learning:** In Elixir/BEAM, using `=~ ~r/enterprise|team/i` compiles and executes regex matches on every invocation, creating significant CPU overhead in hot paths (routing candidate selection, catalog sorting, usage ranking). Using `String.downcase/1` once with explicit `String.contains?/2` checks is over 5x faster and avoids regex engine invocation.
**Action:** Replace dynamic case-insensitive regex checks (`=~ ~r/.../i`) in hot paths with `String.downcase/1` combined with explicit `String.contains?/2` conditions.
