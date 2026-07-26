## 2026-03-06 - [Overriding vs Merging Secure Browser Headers]
**Vulnerability:** Invoking `Phoenix.Controller.put_secure_browser_headers/2` with a custom map (like dynamic Content-Security-Policy) completely overrides and strips default security headers (e.g. `X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`, etc.).
**Learning:** Standard browser security headers must be explicitly merged with custom dynamic headers like CSP to avoid exposing browser clients to clickjacking, mime-sniffing, and cross-site scripting risks.
**Prevention:** Always maintain a baseline map of secure default browser headers when setting dynamic browser response headers via custom plugs/controllers.
