## 2024-05-18 - Fix Formula Injection in CSV Exports
**Vulnerability:** Multiple CSV export endpoints failed to sanitize user inputs that could be interpreted as formulas by spreadsheet applications (CSV/Formula Injection).
**Learning:** Any data exported to CSV format must be sanitized if it begins with formula trigger characters (`=`, `+`, `-`, `@`), even if the values are otherwise properly enclosed in quotes.
**Prevention:** Always implement a centralized or uniform escaping function for CSV values that prepends a single quote (`'`) to values starting with `=`, `+`, `-`, or `@` to force the spreadsheet to interpret them as plain text.
