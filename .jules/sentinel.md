## 2026-03-06 - Prevent DoS from Dynamic Atom Creation in Settings Map Key Access
**Vulnerability:** Unsafe conversion of untrusted/dynamic string keys to atoms using `String.to_atom/1` in helper functions like `map_get/2` can allow remote or untrusted input to exhaust the Erlang VM atom table (which is not garbage collected), causing VM crashes and Denial of Service.
**Learning:** Functions that look up string/atom keys in maps/structs when parsing or normalizing configuration parameters may receive unvetted dynamic key names.
**Prevention:** Always use `String.to_existing_atom/1` wrapped in a `try/rescue ArgumentError` block or explicit pattern matching on known safe keys rather than `String.to_atom/1`.
