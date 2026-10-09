## 2026-10-09 - Short-circuiting candidate dropped set calculation in route filtering

**Learning:** In Elixir gateway routing selection, list filtering operations often pass through without dropping any candidates. Computing set differences using `MapSet.new` and `Enum.reject` on every request incurs ~2x unnecessary CPU overhead (map struct allocations, key hashing, and list traversals). Short-circuiting with `classified_candidates == candidates` and `candidates == []` eliminates map allocations entirely on hot request routing paths.

**Action:** Before generating set differences or performing `MapSet` allocations on list transformations in hot paths, check if the source and result lists are identical (`xs == ys`) or empty (`ys == []`) first.
