## 2026-09-24 - Short-circuiting candidate list transformations in Bridge Ring routing

**Learning:** On hot execution paths (such as gateway candidate routing executed per-request), list pipeline operations (`Enum.with_index`, `Enum.sort_by`, `Enum.split`, `Enum.split_with`, `++`) incur noticeable GC allocations and execution overhead. When candidate counts are <= 1, rotation shift is 0, routing priorities across candidates are equal, or the affinity target is already list head, short-circuiting returns the list directly without intermediate allocations.

**Action:** Look for candidate routing or list filtering pipelines in high-frequency request paths and check if fast-path short-circuits can eliminate list traversals and allocations on the happy path.
