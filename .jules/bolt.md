## 2026-10-12 - SSE Field Extraction Optimization

**Learning:** In SSE stream block parsing (`SSEParser.sse_field/2`), checking for field prefix existence via `String.contains?(block, prefix)` before splitting lines eliminates string splitting and list allocations for missing SSE fields (like `event:` in 99%+ of streaming chunks). Also, replacing multi-pass `Enum.map` + `Enum.flat_map` with a single-pass tail-recursive accumulator avoids intermediate trimmed line list allocations.
**Action:** When extracting fields from text blocks in hot streaming paths, check substring existence before string splitting and use single-pass tail recursion for line processing.
