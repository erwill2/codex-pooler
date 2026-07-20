# Sentinel Security Journal

## 2026-07-20 - Custom secure headers helper overriding standard security headers
**Vulnerability:** A custom browser security header implementation overrode standard security headers with only Content-Security-Policy (CSP). This left the browser interface lacking clickjacking (X-Frame-Options), MIME sniffing (X-Content-Type-Options), XSS filter, Referrer-Policy, and other defense-in-depth protections.
**Learning:** In Phoenix, `Phoenix.Controller.put_secure_browser_headers/2` replaces default headers entirely if a custom map is provided. Returning only `content-security-policy` in custom header generation logic unintentionally stripped the other default protections.
**Prevention:** Always merge custom or dynamic headers (like CSP) with standard, static security headers to maintain defense-in-depth.
