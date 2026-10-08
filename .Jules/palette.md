## 2026-10-08 - Accessible Form Input Errors with Single Container IDs
**Learning:** When connecting Phoenix LiveView form inputs to error messages via `aria-describedby`, wrapping the errors in a single container `div` with `id={"#{@id}-error"}` rather than applying the `id` directly to looped error paragraphs prevents duplicate `id` DOM attributes when multiple errors exist on a single field.
**Action:** Always wrap field-level error messages in a single container div with `id={"#{@id}-error"}` and set `aria-describedby={if @errors != [], do: "#{@id}-error"}` on the input control.
