## 2025-01-20 - CSV Formula Injection Prevention
**Vulnerability:** Multiple CSV export utilities (`toCSV`, `csvEscape`, `toCsvCell`, etc.) across UI and library files lacked escaping for characters that could trigger formula execution in spreadsheet applications (CSV Injection).
**Learning:** Formula injection is a recurring pattern in projects that export tabular data. We established a reusable security pattern for this codebase where all CSV export logic must defensively escape fields starting with `=`, `+`, `-`, or `@`.
**Prevention:** Always prepend a single quote (`'`) to string values beginning with `=`, `+`, `-`, or `@` during CSV serialization.

## 2026-05-28 - Path Traversal Prevention
**Vulnerability:** The `/api/pack/:packId/download.zip` endpoint used unvalidated user input (`packId`) in `path.join()`, allowing path traversal.
**Learning:** Any user-supplied identifier used to construct file system paths must be strictly validated against an allowed character set to prevent directory traversal attacks, even if `path.join()` is used, as it does not prevent traversing upwards if the input contains `../`.
**Prevention:** Always validate identifiers (like `tenantId` and `packId`) against strict regular expressions (e.g., `^[a-zA-Z0-9_-]+$`) before using them in file paths.
