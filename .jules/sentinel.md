## 2025-03-06 - [Phoenix put_secure_browser_headers/2 Complete Override]
**Vulnerability:** Invoking `Phoenix.Controller.put_secure_browser_headers/2` with a custom headers map completely overrides and deletes standard/default security headers (like X-Frame-Options, X-Content-Type-Options) rather than merging them.
**Learning:** This strips essential browser-level clickjacking and MIME-sniffing protections when custom dynamic Content-Security-Policy headers are applied.
**Prevention:** Explicitly define and merge default secure headers with custom dynamic headers before passing them to `put_secure_browser_headers/2`.
