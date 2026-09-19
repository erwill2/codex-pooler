# Bolt Journal - Performance Learnings

## 2026-09-19 - String.contains? vs Regex in Plan Ranking
**Learning:** Using dynamic case-insensitive regular expressions (`plan =~ ~r/enterprise|team/i`) inside routing and candidate evaluation loops incurs overhead. Converting the string with `String.downcase/1` and checking substrings via `String.contains?/2` is over 2x faster in BEAM micro-benchmarks while preserving identical case-insensitive matching logic.
**Action:** Replace dynamic case-insensitive regexes with downcasing and explicit `String.contains?/2` checks in high-frequency candidate ranking and filtering functions.
