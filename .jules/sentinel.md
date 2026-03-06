## 2025-01-15 - CSV Formula Injection (Macromagic) in export logic
**Vulnerability:** The `ticketsToCsv` export function failed to sanitize cell values starting with `=`, `+`, `-`, or `@`.
**Learning:** Spreadsheets (like Excel, Google Sheets) execute these symbols as formulas, which can lead to data exfiltration or arbitrary code execution on the end-user's machine when exporting a CSV from untrusted user input.
**Prevention:** Always prepend a single quote (`'`) to CSV cell values that begin with these sensitive characters to force them to be interpreted as text rather than formulas.
