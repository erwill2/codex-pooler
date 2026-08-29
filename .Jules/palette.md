## 2026-08-29 - Contextual ARIA Labels on Metric Link Overlays
**Learning:** Overlay link elements that cover card metric cells can be ambiguous to screen reader users if given static labels like "Open Upstreams". Incorporating the specific parent item name and dynamic metric value into the link's `aria-label` gives screen reader users full context during tab/link navigation.
**Action:** Always include entity identifiers and current formatted metric states in overlay link `aria-label` attributes.
