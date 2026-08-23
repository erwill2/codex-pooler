# Bolt Performance Journal

## 2026-07-22 - Optimizing Case-Insensitive Substring Plan Matching in Routing Hot Paths
**Learning:** In Elixir, case-insensitive plan matching on every candidate ranking call using dynamic regexes (`plan =~ ~r/enterprise|team/i`) incurs heavy overhead from Regex evaluation/execution. Converting the plan string to lower case once with `String.downcase/1` and matching with explicit `String.contains?/2` using `or` conditions is >5.5x faster. Note that passing a list of substrings to `String.contains?/2` (e.g. `String.contains?(plan, ["enterprise", "team"])`) is slower than explicit `or` conditions because Elixir dynamically compiles list patterns at runtime.
**Action:** Always prefer `String.downcase/1` + explicit `String.contains?/2` `or` checks over dynamic regex matching in candidate selection and routing hot paths.
