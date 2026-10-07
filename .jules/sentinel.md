## 2026-10-07 - URL Decoding Before Return Path Validation
**Vulnerability:** Open redirect in Elixir Phoenix session return path validation when checking `return_to` strings.
**Learning:** Checking for leading `//` without prior `URI.decode/1` allows URL-encoded characters (`%2f`, `%5c`), backslashes (`/\`), or tab/whitespace sequences (`/\t`, `/\n`, `/\r`) to bypass string prefix checks while still causing browsers to interpret the path as an absolute protocol-relative URL.
**Prevention:** Always decode return paths using `URI.decode/1` before validating that the path starts with `/` and does not start with unsafe leading sequences (`//`, `/\`, `/\t`, `/\n`, `/\r`).
