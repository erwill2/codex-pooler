## 2026-10-13 - Avoid List Pattern Arguments in String.contains?/2 Hot Paths

**Learning:** Passing a list of strings to `String.contains?/2` in Elixir causes dynamic runtime list pattern construction and compilation. Checking multi-substring presence with explicit `or` conditions using binary pattern literals allows Elixir to avoid list allocation and short-circuit immediately.
**Action:** When matching multi-substring patterns in streaming/hot execution paths, use explicit `or` conditions with binary literals (`String.contains?(s, "a") or String.contains?(s, "b")`) instead of list arguments (`String.contains?(s, ["a", "b"])`).
