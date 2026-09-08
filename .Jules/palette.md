## 2026-07-20 - Overlay Link ARIA Labels for Metric Cards
**Learning:** When card cell wrappers use overlay link targets (e.g., Fitts's Law cell wrapper links), screen reader users focusing the overlay link hear only static action labels (like "Open Upstreams") unless dynamic cell metrics are explicitly incorporated into the `aria-label`.
**Action:** Always construct dynamic `aria-label` attributes on overlay link targets (e.g. `aria-label={"Open #{@label} details, current: #{@value}"}`) so screen readers vocalize both the navigation target and the current value.
