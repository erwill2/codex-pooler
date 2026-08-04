# Bolt's Performance & Optimization Journal

## 2026-08-04 - Over 5.5x Faster Case-Insensitive String Checks
**Learning:** For case-insensitive plan matching or general substring checks in hot paths, converting the string with `String.downcase/1` and checking substring matches using `String.contains?/2` is significantly faster (over 5.5x speedup) than executing dynamic regular expressions with `=~ ~r/.../i`. Furthermore, when optimizing case-insensitive multi-substring matching, checking a list of substrings (e.g. `String.contains?(s, ["a", "b"])`) is substantially slower than explicit `or` conditions (e.g. `String.contains?(s, "a") or String.contains?(s, "b")`) because Elixir dynamically compiles list patterns at runtime.
**Action:** Always replace case-insensitive regular expression matching on fixed lists of substrings with lowercased explicit `String.contains?/2` using `or` conditions in hot paths like candidate routing, upstream catalog matching, and pricing.

## 2026-08-04 - ExUnit Multi-Iteration Test Database Record Accumulation
**Learning:** When writing multi-iteration loops (e.g. `for size <- [1, 50]`) or parameter-driven sequences within a single ExUnit test, state/database records accumulate within the single test sandbox transaction, causing subsequent iterations to see stale records from prior iterations.
**Action:** Explicitly use `Repo.delete_all/1` on relevant schemas (such as Model, PoolUpstreamAssignment, UpstreamIdentity, Pool) at the start of each iteration in multi-iteration ExUnit loops to ensure clean independent states.
