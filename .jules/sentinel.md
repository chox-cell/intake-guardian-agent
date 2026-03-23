## 2024-05-24 - Prevent CSV Formula Injection
**Vulnerability:** CSV export functions (`ticketsToCsv`) were vulnerable to CSV Formula Injection (DDE injection) because fields starting with `=`, `+`, `-`, or `@` were not properly escaped.
**Learning:** User input that starts with specific formula characters can be executed by spreadsheet applications when opening exported CSV files, leading to arbitrary code execution.
**Prevention:** Prepend a single quote (`'`) to any CSV field that starts with `=`, `+`, `-`, or `@` before exporting data.
