## 2026-03-06 - Accessible Required Field Indicators
**Learning:** When adding visual required indicators (such as red asterisks) to form input labels in Phoenix components, using `aria-hidden="true"` hides the purely visual symbol from screen readers which already announce the field's `required` attribute natively.
**Action:** Always wrap visual `*` indicators in `<span class="text-error ml-0.5" aria-hidden="true">*</span>` inside component label templates when `@rest[:required]` is present.
