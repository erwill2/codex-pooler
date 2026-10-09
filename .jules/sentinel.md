## 2026-10-09 - Phoenix `put_secure_browser_headers/2` Overrides Default Headers
**Vulnerability:** Invoking `Phoenix.Controller.put_secure_browser_headers/2` with a custom map strips standard browser protection headers (`x-frame-options`, `x-content-type-options`, `x-download-options`, `x-permitted-cross-domain-policies`, `referrer-policy`) because Phoenix replaces the default header map entirely instead of merging key-by-key.
**Learning:** Providing custom headers to `put_secure_browser_headers` suppresses all defaults unless explicitly merged in the custom map function.
**Prevention:** Always include default secure browser header keys alongside custom headers (such as dynamic CSP) when returning custom header maps in `put_secure_browser_headers`.
