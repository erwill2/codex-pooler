# Bolt Journal

## 2026-07-21 - [Precompiled Patterns and Regexes in Hot Paths]
**Learning:** Compiling `:binary.compile_pattern/1` in a module attribute fails because it returns a `#Reference` type, which is transient and cannot be serialized/escaped into BEAM compiled files (as references are node-boot transient). Regular expressions compiled with `~r/.../` in module attributes, however, are fully serializable and are compiled once at load-time.
**Action:** Use regular expressions compiled in module attributes (`@regex ~r/.../i`) for pre-compilation, and avoid storing transient pattern references in module attributes.
