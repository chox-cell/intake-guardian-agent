## 2025-01-20 - CSV Formula Injection Prevention
**Vulnerability:** Multiple CSV export utilities (`toCSV`, `csvEscape`, `toCsvCell`, etc.) across UI and library files lacked escaping for characters that could trigger formula execution in spreadsheet applications (CSV Injection).
**Learning:** Formula injection is a recurring pattern in projects that export tabular data. We established a reusable security pattern for this codebase where all CSV export logic must defensively escape fields starting with `=`, `+`, `-`, or `@`.
**Prevention:** Always prepend a single quote (`'`) to string values beginning with `=`, `+`, `-`, or `@` during CSV serialization.

## 2025-01-22 - Open Redirect via Host Header Injection
**Vulnerability:** Application redirects constructed absolute URLs from `X-Forwarded-Host` or `Host` headers, allowing an attacker to manipulate the header and redirect users to malicious domains, potentially leaking sensitive query parameters like `k` (tenantKey).
**Learning:** Using untrusted request headers to build absolute URLs for internal redirects introduces Open Redirect vulnerabilities.
**Prevention:** Prefer relative paths for internal redirects (e.g., `res.redirect('/path')`). If an absolute URL is required for cross-domain configurations, rely on explicitly trusted configuration variables like `process.env.APP_BASE_URL` instead of request headers.
