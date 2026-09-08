## 2026-03-30 - Prevent Atom Table Exhaustion via Dynamic Interpolation

**Vulnerability:** Interpolating string variables into atom creation (e.g. `:"#{key}_iso"`) creates arbitrary atoms dynamically. In Erlang/BEAM, atoms are stored in a fixed system atom table and are never garbage-collected, making dynamic atom creation a Denial-of-Service (DoS) memory exhaustion vulnerability.

**Learning:** Static analysis tools like Sobelow flag `DOS.BinToAtom` when string interpolation is converted to atoms. Even if `key` is expected to be a controlled atom or safe parameter within the internal codebase, using explicit pattern matching on known safe key values eliminates the risk completely and satisfies security linter requirements.

**Prevention:** Never use dynamic string interpolation to create atoms (`:"#{var}_ext"` or `String.to_atom/1`). Always use explicit `case`/pattern matching on allowed atom values, static maps, or `String.to_existing_atom/1`.
