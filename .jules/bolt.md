## 2026-09-11 - BridgeRing candidate pipeline short-circuiting
**Learning:** In gateway routing pipeline transformations (`apply_routing_priority`, `apply_affinity`, `rotate_candidates`), avoiding list allocations, `Enum.with_index`, and `Enum.sort_by` when candidates count <= 1, shift is 0, or equal priority or head matching occurs eliminates unnecessary intermediate tuple/list allocations on hot dispatch paths.
**Action:** Always check list length <= 1, equal priorities, or matching head before performing list splitting, sorting, or rotation in routing pipelines.
