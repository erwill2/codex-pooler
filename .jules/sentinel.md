## 2026-10-10 - Open Redirect via Encoded Return Paths
**Vulnerability:** URL-encoded or backslash-encoded return paths (e.g., `/%2fevil.com`, `/%5cevil.com`) bypassed `safe_return_to_path/1` string checks.
**Learning:** Checking raw strings for unsafe leading sequences without URI-decoding first allows browser-normalized URL bypasses.
**Prevention:** Always URI-decode untrusted path strings via `URI.decode/1` prior to checking for leading slashes/backslashes or control characters.
