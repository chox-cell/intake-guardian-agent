## 2025-01-20 - Prevent CSV Injection in Exports
**Vulnerability:** Multiple CSV export functions (`toCsv`, `csvEscape`, `toCsvCell`, `ticketsToCsv`, `exportCsv`) across the codebase failed to sanitize fields starting with `=`, `+`, `-`, or `@`.
**Learning:** Unsanitized inputs starting with these characters can trigger formula execution (CSV Injection/Formula Injection) when the exported CSV is opened in spreadsheet applications like Microsoft Excel or Google Sheets, potentially leading to arbitrary code execution or data exfiltration.
**Prevention:** All fields in CSV exports must be sanitized by prepending a single quote (`'`) to values starting with formula prefix characters (`=`, `+`, `-`, `@`) before applying standard CSV quoting.
