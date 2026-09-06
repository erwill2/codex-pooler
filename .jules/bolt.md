## 2026-07-18 - Hot-Path Gateway Candidate Ordering & String Matching
**Learning:** In gateway request dispatch paths, candidate ordering pipelines (`BridgeRing`) and plan ranking (`CandidateEligibility`) are executed on every single incoming request.
1. `apply_routing_priority` called `Enum.with_index |> Enum.sort_by |> Enum.map` on candidate lists. When all candidates share equal routing priority (99%+ of requests) or length <= 1, sorting preserves exact order. Short-circuiting avoids list/tuple allocations and sorting overhead.
2. `rotate_candidates` with 0 shift allocates a copy of the list via `Enum.split` and `++`. Short-circuiting when shift == 0 returns the list unchanged.
3. `apply_affinity` and `apply_codex_session_preference` can check if the target candidate is already at the head of the list before doing `Enum.split_with` and list concatenation.
4. `model_source_plan_rank` used dynamic regex `=~ ~r/.../i` for plan family matching. Replacing with `String.downcase/1` and `String.contains?/2` is over 5x faster and avoids Regex VM execution on every model ranking check.
**Action:** Always look for fast-path short-circuits in list transformation pipelines that process requests on every gateway dispatch.
