## 2026-07-20 - Optimize Token Counter List Operations in BPE and Pretokenizer

**Learning:** In Elixir token counting and compression paths, `BPE.merge_at/2` using `Enum.split/2` and `++` causes unnecessary 2-tuple allocations and double list traversals per merge step. Replacing this with recursive pattern matching (`[first, second | rest]`) avoids tuple allocations and performs single-pass list merging. Additionally, `Regex.scan/2` returns a list of single-element lists (`[[match1], [match2], ...]`), where `Enum.map(&hd/1)` extracts matches directly without the deep recursive list flattening overhead of `List.flatten/1`.

**Action:** Prefer direct recursive pattern matching over `Enum.split/2` + `++` when updating list elements at a known index, and use `Enum.map(&hd/1)` over `List.flatten/1` for flat `Regex.scan/2` results in hot execution paths.
