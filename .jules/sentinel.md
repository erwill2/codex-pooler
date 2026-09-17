## 2026-07-22 - Prevent Erlang Atom Table Exhaustion in Evaluators
**Vulnerability:** Dynamic atom creation via interpolated strings (`:"#{key}_iso"`) in alert evaluator functions.
**Learning:** In the BEAM VM, atoms are stored in a global atom table and are never garbage collected. Creating dynamic atoms from runtime data risks exhausting the atom limit (1,048,576 by default) and crashing the entire node (DoS).
**Prevention:** Use explicit pattern-matched function clauses or lookup maps on known atom keys rather than interpolated dynamic atom creation.
