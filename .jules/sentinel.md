## 2025-01-08 - CSV Formula Injection Mitigation
**Vulnerability:** CSV exports across the application (e.g. `csvEscape`, `toCsvCell`, `toCsv`) did not escape formula injection characters, potentially allowing execution of arbitrary formulas in spreadsheet software.
**Learning:** It is crucial to sanitize fields starting with `=`, `+`, `-`, or `@` across all CSV export points, as untrusted data (like ticket subjects or sender names) might be rendered in CSV.
**Prevention:** Prepend a single quote (`'`) to fields starting with `=, +, -, @` in all CSV conversion utilities.
