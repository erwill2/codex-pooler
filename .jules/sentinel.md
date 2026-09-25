## 2026-09-25 - Open Redirect Bypass via Encoded/Backslash Paths in Session Return Paths
**Vulnerability:** Naive `String.starts_with?(path, "/") and not String.starts_with?(path, "//")` checks allow open redirect bypasses using backslashes (`/\evil.com`), URL-encoded backslashes (`/%5Cevil.com`), or whitespace/control characters (`/\tevil.com`).
**Learning:** Browsers normalize backslashes and URL-encoded characters in `Location` headers into protocol-relative URLs (`//evil.com`), redirecting users to external malicious domains upon authentication.
**Prevention:** Always decode the path via `URI.decode/1` before validating that the target path does not start with `//`, `/\\`, `/\t`, `/\n`, or `/\r`.
