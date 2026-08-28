## 2026-07-19 - Form Input Error Accessibility with ARIA
**Learning:** Phoenix LiveView form components rendering inline error lists should associate inputs via `aria-describedby` and set `aria-invalid="true"` when errors are present. Wrapping errors in a single container `div` with `id={"#{@id}-error"}` prevents duplicate ID DOM attributes when multiple errors exist.
**Action:** Always wrap error lists in a single error container div with `id={"#{@id}-error"}` and bind `aria-describedby` and `aria-invalid` on form inputs.
