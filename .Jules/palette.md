## 2026-09-17 - Single Container wrapper for Input Error ARIA Associations
**Learning:** When connecting LiveView form inputs to validation error messages via `aria-describedby`, applying `id={"#{@id}-error"}` directly to looped error paragraphs (`<p :for={msg <- @errors}>`) generates duplicate DOM IDs when multiple validation errors exist for a single field, violating HTML validity.
**Action:** Wrap field error messages in a single parent container `<div :if={@errors != []} id={@id && "#{@id}-error"}>` so `aria-describedby` uniquely targets one container element.
