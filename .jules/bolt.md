## 2026-10-14 - Gateway Candidate List Short-Circuiting
**Learning:** In gateway candidate routing pipelines, candidates are very frequently unchanged during eligibility filtering passes. Doing structural `==` equality or empty list checks before performing set differences (`MapSet.new` + `Enum.reject`) eliminates unnecessary map set allocations, hashing, and list traversals on hot request paths.
**Action:** When filtering candidate lists or computing dropped items in routing steps, short-circuit `classified_candidates == candidates` and empty list cases before building `MapSet`s.
