## 2025-01-08 - [Formula Injection in CSV Exports]
**Vulnerability:** The application's CSV export logic lacked proper sanitization against formula injection (also known as CSV injection), specifically when values started with `=`, `+`, `-`, or `@`.
**Learning:** Formula injection is a common vector where malicious users input specially crafted strings (e.g. `=cmd|' /C calc'!A0`) that execute commands if a victim opens the exported CSV file in spreadsheet software like Excel. Standard CSV escaping of commas and quotes isn't enough to prevent this.
**Prevention:** Always prepend a single quote (`'`) to any field starting with `=`, `+`, `-`, or `@` during CSV generation to force the spreadsheet software to interpret the value as plain text rather than a formula.
