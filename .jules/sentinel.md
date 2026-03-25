## 2026-03-25 - CSV Formula Injection
**Vulnerability:** User-controlled input in tickets was exported to CSV without escaping fields that start with formula characters (=, +, -, @), leading to potential arbitrary code execution if opened in spreadsheet software like Microsoft Excel.
**Learning:** When exporting user-generated data to CSV, all fields must be sanitized by prepending a single quote to prevent spreadsheet software from evaluating them as formulas.
**Prevention:** Ensure any CSV export logic escapes fields starting with =, +, -, or @ by prepending a single quote (') before adding the field to the CSV output.
