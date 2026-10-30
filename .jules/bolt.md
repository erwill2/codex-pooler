## 2026-10-30 - MapSet short-circuiting on gateway candidate route filtering

**Learning:** Building `MapSet` collections to perform set difference operations (`Enum.reject(candidates, &MapSet.member?)`) on routing hot paths introduces unnecessary map allocations, tuple allocations, and hash computations when no candidates are dropped (the common happy path where `classified_candidates == candidates`).
**Action:** Always short-circuit set operations by checking list equality (`classified_candidates == candidates -> []`) or empty list conditions (`candidates == [] -> classified_candidates`) before allocating sets or performing element lookups.
