## 2025-01-20 - Prevent CSV Injection in Exports
**Vulnerability:** Multiple CSV export functions (`toCSV`, `toCsvCell`, `csvEscape`, `esc`) across UI and storage layers did not escape formula characters (`=`, `+`, `-`, `@`), leaving the application vulnerable to CSV Injection (Formula Injection).
**Learning:** Standard CSV escaping logic (wrapping in quotes and doubling quotes) handles formatting but does not prevent spreadsheet applications (like Excel or Google Sheets) from interpreting cell contents as executable formulas.
**Prevention:** Always prepend a single quote (`'`) to any CSV field that begins with a formula indicator character to force the spreadsheet to interpret the cell as literal text.
