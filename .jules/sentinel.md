## 2026-08-09 - [DoS via Erlang Atom Table Exhaustion]
**Vulnerability:** Denial of Service (DoS) via dynamic atom interpolation inside aggregate operations.
**Learning:** Using dynamic atom interpolation like `:"#{key}_iso"` creates atoms at runtime based on variables. In Erlang/BEAM, the atom table has a hard limit (by default 1,048,576 atoms) and atoms are never garbage-collected. If untrusted or dynamic variables are interpolated into atoms, it can cause the VM to crash or suffer from Denial of Service (DoS) due to atom table exhaustion.
**Prevention:** Avoid dynamic atom generation or interpolation. Use pattern matching, explicit static mapping, or `String.to_existing_atom` wrapped with a `try/rescue` block to ensure only predefined atoms are referenced.
