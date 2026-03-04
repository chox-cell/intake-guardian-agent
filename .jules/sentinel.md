## 2025-03-04 - CSV Formula Injection in ticketsToCsv

**Vulnerability:** The `ticketsToCsv` function in `src/lib/ticket-store.ts` allowed strings starting with `=`, `+`, `-`, or `@` to be exported into a CSV format without proper escaping. This can lead to CSV Formula Injection when the file is opened by spreadsheet programs, allowing execution of malicious commands or data exfiltration.

**Learning:** When exporting user-controlled data to CSV, simply escaping quotes and wrapping in quotes is not sufficient if the data can be interpreted as a formula by spreadsheet software (like Excel or Google Sheets). This was a surprising gap as standard escaping logic didn't account for spreadsheet behavior.

**Prevention:** Always validate and sanitize user input before export. When generating CSVs containing user input, explicitly check for and escape formula prefixes (`=`, `+`, `-`, `@`) by prepending a single quote (`'`), ensuring the software treats the value as literal text.
