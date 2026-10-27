## 2026-10-27 - Visual Required Indicators for Form Input Labels
**Learning:** Adding a red asterisk next to form input labels when `required` is present provides clear visual feedback to users. Setting `aria-hidden="true"` on the asterisk ensures screen readers aren't burdened with duplicate visual announcements since they already natively announce the input's `required` attribute.
**Action:** Always wrap visual required indicators (like red asterisks) in `<span aria-hidden="true">*</span>` when enhancing form field labels in Phoenix components.
