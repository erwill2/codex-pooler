## 2026-07-18 - Custom CSP Maps Override Default Secure Browser Headers in Phoenix
**Vulnerability:** Passing a custom map containing only `content-security-policy` to `Phoenix.Controller.put_secure_browser_headers/2` completely replaces Phoenix's default secure browser headers rather than merging with them, stripping `x-frame-options`, `x-content-type-options`, `x-xss-protection`, and other browser protections.
**Learning:** `Phoenix.Controller.put_secure_browser_headers/2` overrides default headers when provided a custom map argument.
**Prevention:** Always explicitly define or merge default secure browser headers into custom header generator functions like `CodexPoolerWeb.BrowserSecurity.secure_headers/1` when passing custom maps to `put_secure_browser_headers/2`.
