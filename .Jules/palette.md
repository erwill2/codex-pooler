## 2026-07-18 - Accessible Client-Side Clipboard Copy Announcements

**Learning:** When client-side copy interactions update visual icons and labels, screen reader users do not receive feedback without explicit `aria-live="polite"` region announcements. Directly vocalizing raw clipboard content can expose sensitive tokens or create poor voice UX with large texts, so announcing a safe description (from `aria-label`, `title`, or fallback) along with the action status is ideal.

**Action:** Refactor client-side copy hooks to compute button label descriptions prior to state mutation, trigger an `aria-live="polite"` announcement, and update `aria-label` dynamically while preserving original attributes for restoration.
