# Sentinel Security Journal

## 2026-03-06 - Prevent DoS via Unsafe Dynamic Atom Creation in Settings & Forms
**Vulnerability:** In `lib/codex_pooler/instance_settings/settings.ex`, `map_get/2` attempted `String.to_atom/1` on arbitrary string keys from untrusted input/params maps.
**Learning:** In BEAM/Erlang, atoms are globally shared and never garbage collected. Converting untrusted string parameters via `String.to_atom/1` can exhaust the atom table (1M limit) and crash the entire BEAM node. In LiveView forms, using `String.to_existing_atom/1` on uninitialized dynamic field strings can raise `ArgumentError` if the atom wasn't loaded into BEAM yet.
**Prevention:** Always use compile-time static lookup maps (e.g., `@field_atoms`) for known field parameters or wrap `String.to_existing_atom/1` in a guarded `try/rescue` block to prevent VM crashes and runtime errors.
