## 2025-01-20 - CSV Formula Injection Prevention
**Vulnerability:** Multiple CSV export utilities (`toCSV`, `csvEscape`, `toCsvCell`, etc.) across UI and library files lacked escaping for characters that could trigger formula execution in spreadsheet applications (CSV Injection).
**Learning:** Formula injection is a recurring pattern in projects that export tabular data. We established a reusable security pattern for this codebase where all CSV export logic must defensively escape fields starting with `=`, `+`, `-`, or `@`.
**Prevention:** Always prepend a single quote (`'`) to string values beginning with `=`, `+`, `-`, or `@` during CSV serialization.

## 2025-05-29 - Admin Key Timing Attack Prevention
**Vulnerability:** The `adminKeyOk` function in `src/api/admin.ts` used standard string comparison (`===`) for validating the admin key. This allowed potential timing attacks where an attacker could deduce the key length and character by character by measuring the response time.
**Learning:** Security-sensitive string comparisons like authentication tokens or keys must use constant-time operations.
**Prevention:** Always use `crypto.timingSafeEqual` for sensitive comparisons. To prevent leaking the length of the expected key, first hash both the expected key and the provided key (e.g., using SHA-256) and then compare the hashes using `crypto.timingSafeEqual`.
