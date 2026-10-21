## 2026-03-30 - URL-Encoded Open Redirect via `return_to` Session Parameter
**Vulnerability:** `safe_return_to_path/1` in `UserAuth` checked raw strings for leading `//` and backslashes `\` without decoding URL-encoded characters first. Attackers could supply encoded payloads like `/%5cevil.com` or `/%2fevil.com` which passed literal string checks but normalized to cross-origin redirects upon browser/client navigation.
**Learning:** Checking untrusted path inputs against unsafe string fragments or leading patterns before URL decoding allows URL-encoded evasion techniques.
**Prevention:** Always decode untrusted path parameters via `URI.decode/1` before evaluating path structure, leading slashes, or forbidden character fragments.
