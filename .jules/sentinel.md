## 2024-05-24 - [Fix CSV Formula Injection]
**Vulnerability:** CSV export functionality in `src/lib/ticket-store.ts` generated CSV content without escaping fields starting with `=`, `+`, `-`, or `@`.
**Learning:** This exposes the application to CSV Formula Injection (also known as CSV Injection). If a user inputs data starting with these characters, it can be interpreted as a formula when opened in spreadsheet software like Microsoft Excel, potentially executing malicious macros or exfiltrating data.
**Prevention:** Before writing a string field to a CSV cell, always check if it starts with `=`, `+`, `-`, or `@`. If it does, prepend a single quote (`'`) to ensure spreadsheet applications treat the field strictly as text, not a formula.
