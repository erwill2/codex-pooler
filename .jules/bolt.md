## 2026-10-28 - Avoid Enum.sort / Map.keys allocations when checking fixed key maps
**Learning:** In Elixir map validation, comparing `Enum.sort(Map.keys(map)) == Enum.sort(expected_keys)` performs redundant list allocations with `Map.keys/1` and runs $O(N \log N)$ sorting with `Enum.sort/1`.
**Action:** Replace key list sorting comparisons with `map_size(map) == length(expected_keys)` and `Enum.all?(expected_keys, &Map.has_key?(map, &1))` to eliminate list allocations and sorting overhead.
