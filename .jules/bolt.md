## 2026-10-25 - [Short-circuit candidate list ordering in routing BridgeRing]
**Learning:** In Elixir list transformations on hot routing paths, short-circuiting empty (`[]`) and single-element (`[_]`) lists using pattern-matched function heads avoids O(N) sorting (`Enum.sort_by`), hashing (`:crypto.hash`), and quota calculation overhead.
**Action:** Always check if list pipeline operations like sorting/ordering can short-circuit early on `[]` or `[_]` when singletons are common.
