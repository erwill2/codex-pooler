## 2026-03-06 - Replacing PCRE Regex with String.contains? in Hot Paths
**Learning:** For case-insensitive substring checks, using `String.downcase/1` paired with `String.contains?/2` is over 15x faster than executing regular expressions with `=~ ~r/.../i` on the BEAM. It also supports passing a list of substrings (e.g. `["enterprise", "team"]`) directly.
**Action:** Replace `plan =~ ~r/.../i` patterns with pre-downcased substring searches inside critical ranking and candidate-filtering routines.
