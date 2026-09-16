## 2026-05-18 - Prevent Atom Table Exhaustion DoS in Settings Map Lookup
**Vulnerability:** Dynamic atom creation via `String.to_atom/1` on unvetted map keys in settings changeset validation.
**Learning:** `String.to_atom/1` called on untrusted string keys in input maps creates new Erlang atoms which are never garbage collected, allowing attackers to cause VM Denial of Service via atom table exhaustion.
**Prevention:** Use `String.to_existing_atom/1` safely wrapped with `try/rescue ArgumentError` to look up existing BEAM atoms without allocating new ones.
