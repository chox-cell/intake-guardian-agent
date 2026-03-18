## 2024-05-24 - Fix CSV Formula Injection
**Vulnerability:** CSV Formula Injection (Macro Injection) in `ticketsToCsv` export function.
**Learning:** User inputs can be crafted to start with `=`, `+`, `-`, or `@`, causing Excel or other spreadsheet software to execute arbitrary formulas or commands when the exported CSV file is opened.
**Prevention:** Always prepend a single quote (`'`) to strings starting with `=`, `+`, `-`, or `@` during CSV serialization to ensure they are treated as plain text rather than executable formulas.
