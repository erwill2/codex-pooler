## 2026-10-08 - Single-Pass Attribute Extraction in Data Classifiers
**Learning:** In Elixir data classification functions that evaluate attributes across raw maps or structs (such as `WindowClassifier.classify/1`), extracting shared attributes once upfront in a single pass before decision branching or pattern matching eliminates redundant field lookups and string normalizations.
**Action:** When optimizing classification functions called on hot execution paths, refactor multi-clause `cond` or guard chains into a single-pass extraction step followed by pattern-matching `case` expressions.
