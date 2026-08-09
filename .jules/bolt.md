## 2026-03-06 - Optimize case-insensitive plan matching
**Learning:** Checking for substrings or case-insensitive plans using a logical `or` of `String.contains?/2` checks is over 5.5x faster than executing dynamic regular expressions with `=~ ~r/.../i` in hot paths.
**Action:** Always prefer case-insensitive checks with `String.downcase/1` and direct substring checks with explicit logical `or` conditions over dynamic compiled/interpolated regex matching for known string families/values.
