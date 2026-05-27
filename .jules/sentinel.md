## 2025-01-20 - CSV Formula Injection Prevention
**Vulnerability:** Multiple CSV export utilities (`toCSV`, `csvEscape`, `toCsvCell`, etc.) across UI and library files lacked escaping for characters that could trigger formula execution in spreadsheet applications (CSV Injection).
**Learning:** Formula injection is a recurring pattern in projects that export tabular data. We established a reusable security pattern for this codebase where all CSV export logic must defensively escape fields starting with `=`, `+`, `-`, or `@`.
**Prevention:** Always prepend a single quote (`'`) to string values beginning with `=`, `+`, `-`, or `@` during CSV serialization.

## 2025-01-20 - Plaintext Token Storage
**Vulnerability:** Authentication tokens were stored in plain text in `tokens.json`.
**Learning:** Storing tokens in plain text allows attackers to impersonate users if the file system is compromised. We established a reusable security pattern for this codebase where tokens must be hashed before storage.
**Prevention:** Always store tokens as hashes (e.g., SHA-256) instead of plain text, and hash incoming tokens before comparing them to the stored values.
