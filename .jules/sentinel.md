## 2024-05-24 - Fix CSV Injection (Formula Injection)
**Vulnerability:** User input included in CSV exports is not sanitized against formula injection. A malicious user could input fields starting with `=, +, -, or @` which, when opened in spreadsheet software like Excel or Google Sheets, would execute as a formula leading to potential remote code execution or data exfiltration.
**Learning:** CSV exports implemented by string manipulation mapping database rows directly into concatenated CSV values are missing protection against CSV formula execution features. Standard CSV escaping `""` does not prevent the first character from being evaluated as a formula.
**Prevention:** Always prepend a single quote (`'`) to any field starting with `=, +, -, or @` when exporting CSVs.
