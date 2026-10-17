## 2026-10-17 - Fast-path prefix existence check for optional SSE fields
**Learning:** Checking for field prefix existence via `String.contains?(block, prefix)` prior to line splitting in `SSEParser.sse_field/2` eliminates string splitting (`String.split/2`) and intermediate list allocations on streaming chunks where optional SSE fields (e.g. `event:`) are absent.
**Action:** Always guard string parsing operations that split blocks into lines with an O(N) binary substring check (`String.contains?/2`) when target prefixes are optional.
