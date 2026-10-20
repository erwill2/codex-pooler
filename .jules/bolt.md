## 2026-10-20 - Short-Circuit List Difference in Gateway Route Filtering
**Learning:** On hot gateway routing paths, comparing candidate lists for term equality (`classified_candidates == candidates`) or empty lists (`candidates == []`) before performing `MapSet` set operations avoids map allocations, hashing, and list traversals on the happy path.
**Action:** When filtering or calculating dropped/rejected items from candidate lists in Elixir, always check `before == after` (and `after == []`) to return `[]` or `before` directly before building a `MapSet`.
