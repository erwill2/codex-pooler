## 2026-08-19 - Case-Insensitive Plan Substring Matching in Hot Paths
**Learning:** Using `=~ ~r/.../i` in candidate ranking and routing hot paths invokes dynamic regex pattern compilation and execution in BEAM, which is over 8x slower than converting strings once with `String.downcase/1` and matching with `String.contains?/2`.
**Action:** In candidate selection, routing, and usage read models, prefer `String.downcase/1` + explicit `String.contains?/2` checks over case-insensitive regular expressions `=~ ~r/.../i`.
