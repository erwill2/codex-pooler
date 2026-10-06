## 2026-07-20 - SSE Parser Stream Partitioning Optimization
**Learning:** In streaming proxy hot paths processing SSE chunks, multi-pass binary scans (`String.contains?`, `String.ends_with?`) combined with unconditional `String.replace` and list operations (`Enum.drop`, `List.last`, `Enum.reject`) create severe CPU and allocation overhead (~95x slowdown).
**Action:** Replace multi-pass operations with a single `String.split(data, "\n\n")` call and a single-pass tail-recursive accumulator, and guard `String.replace(data, "\r\n", "\n")` with `String.contains?(data, "\r")`.
