## 2026-10-28 - URL-Encoded Open Redirect Prevention
**Vulnerability:** Return paths containing URL-encoded characters (such as `%5c` for `\`) bypassed `safe_return_to_path/1` prefix checks (`starts_with?(return_to, "//")`), allowing open redirects when normalized by browsers.
**Learning:** Checking raw strings before URL decoding fails to catch encoded path separators or backslashes.
**Prevention:** Decode `return_to` strings using `URI.decode/1` prior to evaluating path safety constraints.
