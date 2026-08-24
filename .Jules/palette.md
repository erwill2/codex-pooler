## 2026-07-21 - Form Input ARIA Error Associations in LiveView
**Learning:** In Phoenix LiveView input components rendering multiple validation errors via `:for={msg <- @errors}`, applying `id={"#{@id}-error"}` directly to the error `<p>` tag causes duplicate DOM IDs when multiple validation errors are present.
**Action:** Always wrap the error paragraphs in a single container `<div :if={@errors != []} id={"#{@id}-error"}>` so `aria-describedby` points to a single valid container element in the DOM tree.
