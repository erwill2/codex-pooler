# Sentinel's Journal

## 2026-10-31 - Open Redirect via Encoded Relative Path Sequences
**Vulnerability:** In `CodexPoolerWeb.UserAuth`, `safe_return_to_path/1` validated session `return_to` values only by checking for raw leading `//` and substring fragments (`\\`, `/%09`, `/\t`, `\n`, `\r`) without decoding URL-encoded characters. Attackers could supply encoded paths such as `/%2fexample.com` or `/%5cexample.com`, which start with a single `/` and bypass string checks, but when redirected by browsers or downstream HTTP clients are decoded and treated as protocol-relative URLs (`//example.com`), causing open redirect vulnerabilities.
**Learning:** Checking raw query/path strings for disallowed leading sequences is insufficient because URL decoders and browser location parsers normalize percent-encoded slashes (`%2f`) and backslashes (`%5c`).
**Prevention:** Always decode the URI path with `URI.decode/1` prior to evaluating whether it starts with unsafe sequences (`//`, `/\\`, `/\t`, `/\n`, `/\r`) and verify absence of line break characters (`\n`, `\r`).
