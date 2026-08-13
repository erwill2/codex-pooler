# Bolt's Performance Journal

This journal documents critical performance-related learnings.

## 2025-08-13 - Fast Case-Insensitive Multi-Substring Matching
**Learning:** In Elixir, performing case-insensitive pattern matching on hot paths (such as plan ranking) using =~ with regular expressions like `plan =~ ~r/enterprise|team/i` carries substantial runtime overhead. Converting the string to lowercase with `String.downcase/1` and using `String.contains?/2` with explicit `or` conditions yields a **2.37x speedup** (approx. 57% CPU time reduction). Additionally, using explicit `or` conditions is faster than passing a list of substrings to `String.contains?/2` because list patterns are compiled dynamically at runtime.
**Action:** Always replace dynamic case-insensitive regular expressions (`=~ ~r/.../i`) with `String.downcase/1` and explicit `or` checks of `String.contains?/2` in hot paths.
