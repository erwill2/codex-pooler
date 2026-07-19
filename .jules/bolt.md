## 2026-07-20 - [Optimize JSON String Range Scanner]
**Learning:** Found that list appending (`path ++ [key]` and `path ++ [index]`) inside recursive descent scanners produces $O(N^2)$ behavior relative to nesting depth. Converting to $O(1)$ list prepending and reversing once at the leaf provides a cleaner and significantly faster implementation.
**Action:** Always prefer head-prepending (`[item | acc]`) over list append (`acc ++ [item]`) in recursive traversal algorithms, and reverse the list once at terminal states.
