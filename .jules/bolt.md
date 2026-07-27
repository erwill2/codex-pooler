## 2026-03-01 - [Avoid dynamic regex checks in hot paths]
**Learning:** For case-insensitive plan matching or general substring checks in hot paths, converting the string with `String.downcase/1` and checking substring matches using `String.contains?/2` is significantly faster (over 5.5x speedup) than executing dynamic regular expressions with `=~ ~r/.../i`.
**Action:** Always prefer string downcasing and `String.contains?/2` checks instead of =~ with dynamic case-insensitive regex patterns in high-throughput or frequently called logic.
