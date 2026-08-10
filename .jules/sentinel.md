## 2026-07-20 - [Override of Phoenix Secure Browser Headers]
**Vulnerability:** Invoking `Phoenix.Controller.put_secure_browser_headers/2` with a custom map containing only a Content Security Policy (CSP) completely overrides the default browser security headers (such as `x-frame-options`, `x-content-type-options`, etc.) rather than merging them, stripping critical default browser protections.
**Learning:** In Phoenix, default browser security headers are discarded if custom dynamic headers are set without explicitly merging them.
**Prevention:** Merge dynamic browser security headers like CSP explicitly with the standard secure browser headers.
