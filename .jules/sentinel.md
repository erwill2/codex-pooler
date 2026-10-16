## 2026-03-29 - Overriding Default Secure Browser Headers in Phoenix
**Vulnerability:** Invoking `Phoenix.Controller.put_secure_browser_headers/2` with a custom header map completely replaces Phoenix's default security headers (`x-frame-options`, `x-content-type-options`, `x-xss-protection`), leaving only the explicitly passed header (e.g., `content-security-policy`).
**Learning:** In `CodexPoolerWeb.BrowserSecurity.secure_headers/1`, only `content-security-policy` was returned, which accidentally stripped standard security headers when called in the router.
**Prevention:** Always explicitly include `x-frame-options`, `x-content-type-options`, and `x-xss-protection` when returning custom header maps for `put_secure_browser_headers/2`.
