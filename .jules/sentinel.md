# Sentinel Security Journal

## 2026-03-06 - Prevent Erlang Atom Table Exhaustion via Dynamic Interpolation
**Vulnerability:** Sobelow flagged `DOS.BinToAtom` in `lib/codex_pooler/alerts/evaluation/saved_reset_first_seen_evaluator.ex` due to `:"#{key}_iso"` dynamic atom string interpolation.
**Learning:** Atoms in BEAM are not garbage collected. Dynamically converting string keys or interpolating values into atoms can exhaust the BEAM atom table (1,048,576 atoms max limit), resulting in VM crashes and Denial of Service (DoS).
**Prevention:** Replace dynamic atom creation and string interpolation with explicit function clauses/pattern matching on known safe atom keys, or use `String.to_existing_atom/1` with a rescue block.
