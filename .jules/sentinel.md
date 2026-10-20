## 2026-10-18 - Overriding Default Secure Browser Headers with Custom CSP
**Vulnerability:** Invoking `Phoenix.Controller.put_secure_browser_headers/2` with a custom headers map completely replaces Phoenix's default secure browser headers (`x-content-type-options`, `x-permitted-cross-domain-policies`, `referrer-policy`, etc.) rather than merging with them, leaving browser pipelines without baseline MIME-sniffing and cross-domain protections.
**Learning:** `put_secure_browser_headers` does not perform a map merge internally; passing a custom map completely overrides Phoenix defaults.
**Prevention:** Always merge `baseline_headers` (or `Phoenix.Controller.secure_browser_headers/1`) with custom dynamic headers like CSP when calling `put_secure_browser_headers/2` in router pipelines.
