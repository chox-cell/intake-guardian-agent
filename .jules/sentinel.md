
## 2025-03-28 - Prevent CSV Formula Injection
**Vulnerability:** `ticketsToCsv` functions in `src/lib/ticket-store.ts` and `src/lib/ticket_store.ts` were vulnerable to CSV injection because they did not escape fields starting with formula characters (`=`, `+`, `-`, `@`).
**Learning:** User input exported to CSV files can be executed as formulas by spreadsheet software like Excel, leading to serious security risks (like RCE).
**Prevention:** Always sanitize data being written to CSV files by prepending a single quote (`'`) to values starting with `=`, `+`, `-`, or `@`.
