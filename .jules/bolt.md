## 2026-10-04 - O(1) Pattern Matching vs O(N) length/1 in List Short-Circuiting
**Learning:** In Elixir, using `when length(candidates) <= 1` in function head guards traverses the entire linked list ($O(N)$). Using $O(1)$ pattern matching (`[]` and `[_]`) short-circuits empty and single-element lists without list traversal overhead.
**Action:** Always prefer $O(1)$ pattern matching (`[]` and `[_]`) over `length/1` guard checks when short-circuiting list functions.
