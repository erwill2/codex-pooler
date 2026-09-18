# Bolt Performance Journal

## 2026-07-20 - Extracting Regex.scan matches with Enum.map(&hd/1)
**Learning:** Calling `List.flatten/1` on the list of single-element lists returned by `Regex.scan/2` causes deep recursive list traversal and allocates redundant intermediate list cells. Using `Enum.map(&hd/1)` directly extracts the match head string from each result using the `hd/1` BIF, avoiding tree flattening overhead and reducing memory allocations.
**Action:** Always prefer `Enum.map(&hd/1)` over `List.flatten/1` when processing single-capture or default match results from `Regex.scan/2`.
