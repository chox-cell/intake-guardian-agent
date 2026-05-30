## 2025-01-20 - CSV Formula Injection Prevention
**Vulnerability:** Multiple CSV export utilities (`toCSV`, `csvEscape`, `toCsvCell`, etc.) across UI and library files lacked escaping for characters that could trigger formula execution in spreadsheet applications (CSV Injection).
**Learning:** Formula injection is a recurring pattern in projects that export tabular data. We established a reusable security pattern for this codebase where all CSV export logic must defensively escape fields starting with `=`, `+`, `-`, or `@`.
**Prevention:** Always prepend a single quote (`'`) to string values beginning with `=`, `+`, `-`, or `@` during CSV serialization.

## 2025-01-20 - Timing Attack via Length Checking
**Vulnerability:** Early return on length mismatch in `crypto.timingSafeEqual` wrappers exposed the expected string length to timing attacks.
**Learning:** `crypto.timingSafeEqual` throws an error if buffer lengths don't match, often leading developers to add a length check before calling it. However, this length check breaks the constant-time guarantee and leaks the length of the expected secret string (like auth tokens or tenant keys).
**Prevention:** Always hash both strings using a strong algorithm like SHA-256 before comparing them with `crypto.timingSafeEqual`. This ensures both buffers have a consistent length without leaking the original secret's length.
