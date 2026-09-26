## 2026-03-06 - Preventing BEAM Atom Table Exhaustion in Map Accessors and Evaluators
**Vulnerability:** Dynamic atom creation via `String.to_atom/1` or string interpolation `:"#{key}_iso"` on unvetted string keys can allow malicious or unexpected payloads to exhaust the fixed Erlang/BEAM atom table limit (1,048,576 atoms), leading to an unrecoverable VM crash / Denial of Service.
**Learning:** Sobelow flags `DOS.BinToAtom` and `DOS.StringToAtom` for these constructs.
**Prevention:** Always use explicit pattern-matching maps/functions for known keys, or use `String.to_existing_atom/1` wrapped in a `try/rescue ArgumentError` block to safely query string keys without allocating new atoms.
