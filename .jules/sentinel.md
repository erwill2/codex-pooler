## 2026-03-31 - Open Redirect Prevention via Path Decoding
**Vulnerability:** Return path validation in `safe_return_to_path/1` checked for leading `/` and prohibited `//`, but failed to decode URL-encoded paths or block leading backslashes (`/\`), allowing open redirect bypasses via browser normalization (e.g., `/\example.com`, `/%2fexample.com`, or `/%5cexample.com`).
**Learning:** Browsers normalize backslashes (`/\`) and URL-encoded slashes (`%2f`) in relative HTTP redirect locations into protocol-relative or absolute authority URLs.
**Prevention:** Always decode paths using `URI.decode/1` before validating against unsafe leading sequences (`//`, `/\\`, `/\t`, `/\n`, `/\r`).
