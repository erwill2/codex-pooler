## 2026-10-22 - Optimize Case-Insensitive Substring Match in Hot Paths

**Learning:** In Elixir, evaluating dynamic regexes (`plan =~ ~r/enterprise|team/i`) on string properties during routing and model source ranking incurs regex execution and matching overhead (~3.5x slower). Lowercasing the string once with `String.downcase/1` and matching substrings via `String.contains?/2` with explicit `or` conditions executes significantly faster on hot candidate routing paths.

**Action:** Prefer `String.downcase/1` and `String.contains?/2` with explicit boolean conditions over regexes when matching fixed case-insensitive substring patterns in Elixir performance-critical code.
