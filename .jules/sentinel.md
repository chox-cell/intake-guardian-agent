## 2025-01-20 - CSV Formula Injection Prevention
**Vulnerability:** Multiple CSV export utilities (`toCSV`, `csvEscape`, `toCsvCell`, etc.) across UI and library files lacked escaping for characters that could trigger formula execution in spreadsheet applications (CSV Injection).
**Learning:** Formula injection is a recurring pattern in projects that export tabular data. We established a reusable security pattern for this codebase where all CSV export logic must defensively escape fields starting with `=`, `+`, `-`, or `@`.
**Prevention:** Always prepend a single quote (`'`) to string values beginning with `=`, `+`, `-`, or `@` during CSV serialization.

## 2025-01-20 - Token Hash Storage
**Vulnerability:** Authentication login tokens were stored in plain text in `tokens.json`.
**Learning:** Plain text storage of tokens creates a severe risk of lateral movement if the filesystem is compromised.
**Prevention:** Always hash authentication tokens using a secure algorithm (like SHA-256) before storing them, and compare hashes during validation.
