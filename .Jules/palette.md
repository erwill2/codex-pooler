# Palette's UX & Accessibility Journal

This journal documents critical UX and accessibility (a11y) insights and patterns discovered in the Codex Pooler application.

## 2025-02-14 - Screen Reader Announcements for Copy-to-Clipboard Interactions
**Learning:** Icon-only or plain copy-to-clipboard buttons (like device authorization codes, pool API keys, etc.) are silent to assistive technologies when clicked. Without live region updates or updated ARIA attributes, blind and low-vision users using screen readers receive zero auditory confirmation of a successful clipboard copy.
**Action:** When implementing client-side copy interactions, use `aria-live="polite"` elements and dynamically modify `aria-label` to provide immediate screen reader confirmation alongside visual status transitions.
