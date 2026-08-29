## 2026-07-20 - Precompiling regular expressions vs inline sigils in Elixir BEAM
**Learning:** In Elixir, regular expressions instantiated via sigil `~r/.../` in module attributes compile into module pattern constants at compile-time. Re-declaring regular expression sigils as module attributes in hot paths eliminates repeated pattern compilation overhead across module calls.
**Action:** Lift static regular expression patterns in frequently executed hot-path functions to module attributes `@pattern ~r/.../`.
