# Bolt Performance Journal

## 2026-07-17 - Tail-Recursive List Merges vs. Enum.split/2
**Learning:** In Elixir, sequential merges on lists (such as BPE merging) are often implemented using `Enum.split/2` and the `++/2` operator. While readable, this results in multiple traversals of the list and redundant allocations of intermediate lists and tuples. Replacing these with a tail-recursive helper that accumulates traversed items and uses the highly optimized, native `Enum.reverse/2` reduces the time complexity of the merge operation, cuts GC pressure, and scales significantly better with list size.
**Action:** Avoid `Enum.split/2` and list append (`++/2`) in sequential list-transformation loops. Instead, utilize tail-recursion with an accumulator and reconstruct the list in a single pass using `Enum.reverse/2`.
