## 2025-01-20 - [Fix CSV Injection Vulnerability]
**Vulnerability:** CSV export functions (like `toCSV`, `ticketsToCsv`, `exportCsv`) did not escape values starting with formula characters (`=`, `+`, `-`, `@`), exposing the application to CSV Injection (Formula Injection) vulnerabilities when users download and open CSV exports in spreadsheet applications.
**Learning:** Even internal admin tools and data exports require strict data sanitization. User input that seems harmless can be executed as code by external applications like Microsoft Excel or Google Sheets. All CSV exports should consistently escape potential formula prefixes.
**Prevention:** Always escape fields starting with `=`, `+`, `-`, or `@` by prepending a single quote (`'`) in all CSV export implementations.
