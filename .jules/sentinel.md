## 2026-07-20 - Phoenix Browser Security Header Override Gap
**Vulnerability:** Invoking `Phoenix.Controller.put_secure_browser_headers/2` with a custom map completely overrides the default browser security headers (such as `x-frame-options`, `x-content-type-options`, etc.) rather than merging them.
**Learning:** Custom dynamic headers like CSP must be explicitly merged with standard secure browser headers; otherwise, standard browser protections (e.g. clickjacking protection, MIME-sniffing protection) are silently stripped.
**Prevention:** Maintain a defined map of default standard browser security headers and merge them with custom dynamic headers before passing them to `put_secure_browser_headers`.
