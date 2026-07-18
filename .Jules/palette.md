# Palette's Journal - Codex Pooler UX and Accessibility Insights

This journal documents critical user experience and accessibility learnings discovered while enhancing the Codex Pooler interface.

## 2026-03-05 - Screen Reader-Accessible Clipboard Copy hook
**Learning:** Client-side copying interactions that only update text/labels dynamically do not announce updates to screen readers by default. Creating or updating a visually hidden `aria-live="polite"` live region element dynamically upon copy ensures assistive technologies announce the state change immediately. Additionally, caching the original `aria-label` of the interactive element on mount prevents state corruption from rapid successive clicks.
**Action:** Always capture the original interactive state on mount and use visually hidden `aria-live="polite"` regions for feedback on quick, transient user actions (e.g. copying, saving, deleting).
