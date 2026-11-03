# Sentinel Security Journal

## 2026-11-03 - Open Redirect Protection via Decoded Return-To Validation
**Vulnerability:** In `CodexPoolerWeb.UserAuth`, session return path validation (`safe_return_to_path/1`) only checked the raw encoded URL binary for leading slashes and unsafe fragments (`\\`, `/%09`, `/\t`, `\n`, `\r`). An attacker could supply URL-encoded bypasses such as `/%2fevil.example` or `/%5cevil.example` which decoded to `//evil.example` or `/\evil.example`, allowing an open redirect upon user login.
**Learning:** Browser URL normalization resolves URL-encoded characters (like `%2f` and `%5c`) after redirection. Checking the raw path string without decoding leaves a gap where encoded slashes or backslashes bypass raw substring inspections.
**Prevention:** Always decode untrusted redirect targets with `URI.decode/1` before evaluating path boundaries and inspect both raw and decoded strings for forbidden fragments and protocol-relative prefixes (`//` and `/\\`).
