## 2026-08-01 - Missing Default Browser Security Headers via Custom CSP Override
**Vulnerability:** Overriding Phoenix secure headers with a custom map containing only `"content-security-policy"` completely stripped all default browser protections (such as `X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`, etc.), leaving the application vulnerable to clickjacking and MIME-sniffing.
**Learning:** `Phoenix.Controller.put_secure_browser_headers/2` does not merge custom headers with its built-in defaults; instead, passing any custom map completely replaces the default security headers map.
**Prevention:** Always explicitly merge custom dynamic headers like CSP with standard default secure browser headers before passing them to `put_secure_browser_headers/2`.
