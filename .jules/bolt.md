## 2025-02-14 - [String Case-Insensitive Matching Optimization]
**Learning:** Using regular expressions like `plan =~ ~r/enterprise|team/i` incurs substantial CPU and memory overhead compared to `String.downcase/1` and `String.contains?/2`. Explicitly combining multiple conditions with `or` is also faster than dynamic list pattern compilation.
**Action:** Always optimize hot-path plan classification or pattern matching by downcasing the string first and using sequential `String.contains?/2` calls with boolean operators.
