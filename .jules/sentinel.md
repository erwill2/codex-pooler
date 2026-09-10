## 2026-03-06 - Unsafe Dynamic Atom Generation Prevention
**Vulnerability:** Dynamic string-to-atom conversion (`String.to_atom/1`, interpolated atom literals `:"#{key}_iso"`) with user or map key input.
**Learning:** In the Erlang BEAM VM, atoms are stored in a global atom table and are never garbage collected. Creating dynamic atoms from dynamic map keys or function arguments can lead to Erlang atom table exhaustion (limit ~1,048,576 atoms), causing a VM crash/DoS.
**Prevention:** Always use explicit case/pattern matching on known safe atom keys, static lookup maps, or `String.to_existing_atom/1` wrapped in a `try/rescue` block to handle un-existing atoms safely.
