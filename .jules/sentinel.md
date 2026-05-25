## 2025-01-20 - CSV Formula Injection Prevention
**Vulnerability:** Multiple CSV export utilities (`toCSV`, `csvEscape`, `toCsvCell`, etc.) across UI and library files lacked escaping for characters that could trigger formula execution in spreadsheet applications (CSV Injection).
**Learning:** Formula injection is a recurring pattern in projects that export tabular data. We established a reusable security pattern for this codebase where all CSV export logic must defensively escape fields starting with `=`, `+`, `-`, or `@`.
**Prevention:** Always prepend a single quote (`'`) to string values beginning with `=`, `+`, `-`, or `@` during CSV serialization.

## 2025-01-20 - Plaintext Token Storage Prevention
**Vulnerability:** Authentication tokens were stored in plaintext in `tokens.json`.
**Learning:** Storing tokens in plaintext enables lateral movement or session hijacking if the filesystem or database is compromised.
**Prevention:** Always store authentication tokens as one-way cryptographic hashes (e.g., SHA-256) and verify by hashing the user-provided token.
