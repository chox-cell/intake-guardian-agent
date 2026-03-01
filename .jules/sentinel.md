## 2025-01-08 - [CSV Formula Injection in Export]
**Vulnerability:** The `ticketsToCsv` function did not sanitize field values starting with `=, +, -, @`.
**Learning:** This exposes users opening the CSV in Excel/Google Sheets to formula injection attacks.
**Prevention:** Sanitize field values starting with these characters by prepending a single quote (`'`).
