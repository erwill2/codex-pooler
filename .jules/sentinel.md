## 2026-03-06 - Unsafe Atom Table Exhaustion in Map Lookups & String Interpolation

**Vulnerability:** Unvetted string input was being converted to Erlang atoms using `String.to_atom/1` in `Settings.map_get/2` and dynamic string interpolation `:"#{key}_iso"` in `SavedResetFirstSeenEvaluator.aggregate_datetime_iso/3`. Because Erlang atoms are not garbage collected and stored in a fixed-size atom table, an attacker sending arbitrary string keys could exhaust the BEAM atom table, causing an unrecoverable VM crash and Denial of Service (DoS).

**Learning:** `Sobelow` static analysis flags `DOS.StringToAtom` and `DOS.BinToAtom` when dynamic string keys or interpolation are converted to atoms.

**Prevention:** Always use `String.to_existing_atom/1` wrapped in a `try/rescue ArgumentError` block for dynamic map key lookups, or use explicit pattern-matching maps/functions to map known keys to static atoms.
