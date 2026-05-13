## 2023-10-27 - [Mitigate CSV Injection in Exports]
**Vulnerability:** Formula Injection (CSV Injection) vulnerabilities across all CSV export utilities.
**Learning:** Unsanitized user inputs starting with characters like `=`, `+`, `-`, or `@` can be executed as formulas by spreadsheet applications (like Excel) when the exported CSV is opened, potentially leading to arbitrary command execution or data exfiltration.
**Prevention:** Always prepend a single quote (`'`) to exported fields that start with dangerous characters (`=`, `+`, `-`, `@`) to force the application to treat the field as literal text rather than a formula.
