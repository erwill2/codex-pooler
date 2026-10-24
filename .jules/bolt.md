## 2026-10-24 - Short-circuiting unchanged candidate sets in route filtering
**Learning:** In Elixir list difference operations on gateway routing paths (`RouteFiltering.filter_candidates/6`), comparing lists for structural equality (`classified_candidates == candidates`) on the happy path avoids O(N) MapSet map creation, key hashing, and double list traversal.
**Action:** Always check if candidate lists are unchanged or empty before building set index data structures like `MapSet.new`.
