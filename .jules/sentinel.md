## 2026-03-06 - Dynamic Atom Creation Prevention (Erlang Atom Table Exhaustion DoS)
**Vulnerability:** Unbounded creation of Erlang atoms via `String.to_atom/1` or interpolated atom literals (e.g. `:"#{key}_iso"`) from dynamic map keys allows untrusted input to exhaust the BEAM VM atom table (~1M limit) and trigger an unrecoverable VM crash DoS.
**Learning:** BEAM atoms are never garbage collected. Replacing dynamic atom calls with `String.to_existing_atom/1` inside `try/rescue` or explicit pattern matching on known allowed keys safely prevents atom table exhaustion.
**Prevention:** Always use static pattern matching or `String.to_existing_atom/1` with `try/rescue` when handling dynamic map keys.
