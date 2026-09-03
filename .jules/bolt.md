## 2026-09-03 - Happy-path unsorted validation with error fallback
**Learning:** In Elixir map validation, sorting keys via `Enum.sort_by` for deterministic error ordering adds unnecessary sorting overhead and list allocations on valid payloads. Performing unsorted iteration on the happy path and falling back to sorted iteration only when an error is encountered completely eliminates sorting overhead for valid payloads without altering error reporting contracts.
**Action:** When validating map structures, attempt unsorted validation first and fall back to sorted iteration only on error.
