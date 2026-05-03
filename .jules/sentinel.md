## 2026-05-03 - CSV Formula Injection Mitigation
**Vulnerability:** Multiple CSV export functions did not sanitize data fields that start with formula-triggering characters (=, +, -, @), exposing users to CSV Injection (Formula Injection).
**Learning:** When data is exported to CSV, spreadsheet applications (like Excel or Google Sheets) evaluate cells starting with =, +, -, or @ as formulas. Unsanitized user inputs can lead to arbitrary command execution or data exfiltration when the exported file is opened.
**Prevention:** All CSV export functionalities must systematically check and escape cell values starting with =, +, -, @ by prepending a single quote (') to ensure the cell is treated as plain text rather than an executable formula.
