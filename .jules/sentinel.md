## 2025-01-20 - CSV Formula Injection Prevention
**Vulnerability:** Multiple CSV export utilities (`toCSV`, `csvEscape`, `toCsvCell`, etc.) across UI and library files lacked escaping for characters that could trigger formula execution in spreadsheet applications (CSV Injection).
**Learning:** Formula injection is a recurring pattern in projects that export tabular data. We established a reusable security pattern for this codebase where all CSV export logic must defensively escape fields starting with `=`, `+`, `-`, or `@`.
**Prevention:** Always prepend a single quote (`'`) to string values beginning with `=`, `+`, `-`, or `@` during CSV serialization.

## 2025-05-24 - Timing Attack via timingSafeEqual Length Check
**Vulnerability:** String comparisons using `crypto.timingSafeEqual` leaked the length of the expected key because the code returned early if the lengths of the two buffers mismatched (`a.length !== b.length`).
**Learning:** Returning early on length mismatch defeats the purpose of constant-time comparison by creating a timing side-channel that reveals the expected string length.
**Prevention:** When using `crypto.timingSafeEqual` for variable-length strings, hash both strings (e.g., using SHA-256) before comparison to ensure both buffers are always equal in length.
