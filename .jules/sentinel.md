## 2024-05-24 - CSV Injection Mitigation
**Vulnerability:** Unescaped CSV export fields allow for formula injection.
**Learning:** Missing formula injection checks across all CSV export implementations.
**Prevention:** Prepend single quotes to values starting with `=`, `+`, `-`, or `@`.
