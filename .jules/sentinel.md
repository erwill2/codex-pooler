## 2026-07-27 - Upgrading Bandit to Prevent WebSocket CPU Blow-up DoS
**Vulnerability:** In affected Bandit versions (from 1.11.0 before 1.12.1), an attacker could exploit a quadratic CPU blow-up vulnerability (CVE-2026-65623) during WebSocket fragment reassembly by sending millions of tiny continuation frames, starving the server of CPU.
**Learning:** Hardcoded pinning of third-party server-level packages can cause the application to lag behind critical security patches. Regular automated dependency scanning and flexible version constraints help identify and resolve these vulnerabilities.
**Prevention:** Pin dependencies to secure patched versions (such as `1.12.3`) and regularly run hex package vulnerability audits.

## 2026-07-27 - Preventing Secure Browser Header Stripping on Custom Overrides
**Vulnerability:** Phoenix's `put_secure_browser_headers/2` does not merge with the default set of secure headers when overridden with a custom map. If custom maps (like dynamic CSP headers) are passed without standard headers, default browser protections (such as clickjacking and download protections) are stripped.
**Learning:** Dynamic custom security headers like Content Security Policy must be explicitly merged with standard secure browser headers (like `x-frame-options`, `x-xss-protection`, etc.) to maintain defence-in-depth across various browsers.
**Prevention:** Use a central security module to construct a fully merged map of both static standard secure headers and dynamic headers before calling `put_secure_browser_headers/2`.
