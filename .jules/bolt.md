# Bolt's Performance Journal

## 2026-07-20 - Candidate Ordering Pipeline Short-Circuits in BridgeRing Routing
**Learning:** In hot request-routing pathways, operations like `apply_routing_priority`, `apply_affinity`, and `apply_codex_session_preference` were performing full `Enum.with_index`, `Enum.sort_by`, and `Enum.split_with` transformations even when candidate list length was 0 or 1, when candidates shared equal routing priorities, or when the target assignment was already at the list head. Short-circuiting these checks avoids list rebuilds and tuple allocations per gateway request.
**Action:** Always check for head match or uniform property equality before running list partitioning or multi-tuple sorting pipelines in hot dispatch code paths.
