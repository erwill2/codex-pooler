# Bolt Performance Journal

## 2025-03-06 - Case-insensitive Substring Matching in Hot Paths
**Learning:** In Elixir, compiling and executing dynamic regular expressions with `=~ ~r/.../i` in hot routing or accounting paths is a major performance bottleneck. Converting the string to lowercase using `String.downcase/1` and then matching substrings using `String.contains?/2` is over 5.5x faster.
**Action:** Always prefer `String.downcase/1` followed by `String.contains?/2` with literal strings or lists of strings over dynamic regular expressions for case-insensitive substring checks.
