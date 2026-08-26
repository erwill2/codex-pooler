## 2026-08-26 - SQL LIKE Wildcard Injection Prevention in Email Search Filters
**Vulnerability:** Unescaped SQL `LIKE` wildcard characters (`%`, `_`, `\`) in search query inputs when searching invited emails in `CodexPooler.Access.Invites.ReadModel`.
**Learning:** Parameterized query arguments in Ecto prevent standard SQL injection, but raw user inputs passed into `LIKE` clauses without escaping special wildcard characters enable attackers or users to supply wildcards (`%` or `_`), potentially exposing unwanted rows or degrading database search query performance.
**Prevention:** Always escape user input using a dedicated helper (`escape_like/1` replacing `\`, `%`, and `_`) before concatenating `%` wildcards for Ecto fragment `LIKE` or `ILIKE` queries.
