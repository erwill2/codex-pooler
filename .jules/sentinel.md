# Sentinel Security Journal

## 2026-11-08 - Session Return Path URL-Encoded Open Redirect Bypass
**Vulnerability:** In `CodexPoolerWeb.UserAuth.safe_return_to_path/1`, `return_to` path validation checked for leading `//` and static substrings (`\`, `/%09`, `/\t`, `\n`, `\r`) without first percent-decoding the input. Attackers could supply URL-encoded variants (such as `/%2fexample.com`, `/%5cexample.com`, or `/%0a...`) which bypass raw string checks but may be normalized or interpreted as protocol-relative hostnames or CRLF injections by web browsers upon redirect.
**Learning:** Checking untrusted path strings directly without URL decoding leaves gaps where percent-encoded representations of path delimiters or controls evade prefix and fragment checks.
**Prevention:** In Elixir Phoenix return-to path validation, decode paths with `URI.decode/1` prior to evaluating leading sequences (`//`, `/\`, `/\t`, `/\n`, `/\r`) and disallowed characters (`\`, `\t`, `\n`, `\r`).
