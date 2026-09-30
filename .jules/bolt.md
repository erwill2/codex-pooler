## 2026-09-30 - Direct Recursive Pattern Matching for Index-Based List Merging
**Learning:** In Elixir list operations, modifying or merging elements at a specific index via recursive pattern matching is ~3x faster than using `Enum.split/2` combined with list concatenation (`++`), avoiding intermediate tuple and list allocations during BPE token merging.
**Action:** Replace `Enum.split/2` + `++` with recursive pattern matching when operating on lists in high-throughput hot paths like tokenization or stream parsing.
