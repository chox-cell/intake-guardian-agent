## 2025-01-20 - CSV Formula Injection Prevention
**Vulnerability:** Multiple CSV export utilities (`toCSV`, `csvEscape`, `toCsvCell`, etc.) across UI and library files lacked escaping for characters that could trigger formula execution in spreadsheet applications (CSV Injection).
**Learning:** Formula injection is a recurring pattern in projects that export tabular data. We established a reusable security pattern for this codebase where all CSV export logic must defensively escape fields starting with `=`, `+`, `-`, or `@`.
**Prevention:** Always prepend a single quote (`'`) to string values beginning with `=`, `+`, `-`, or `@` during CSV serialization.

## 2025-05-23 - Path Traversal Prevention
**Vulnerability:** Multiple modules (`src/lib/ticket-store.ts`, `src/lib/ticket_store.ts`, `src/lib/decision/evidence_store.ts`, `src/lib/tickets_pipeline.ts`, `src/lib/tickets_disk.ts`, `src/lib/tickets_store.ts`) constructed file system paths by directly concatenating user-controlled `tenantId` values (e.g., `path.join(dataDir(), "tenants", tenantId)`). This allowed attackers to escape the intended directory structure (e.g., passing `../../`) and access or manipulate unauthorized files.
**Learning:** Security gaps occur when file system endpoints trust unvalidated inputs as path segments. Even when authentication is present, user IDs and similar strings must not be blindly treated as safe path segments. A centralized validation or abstraction prevents this pattern.
**Prevention:** Always validate `tenantId` and similar path segments against an explicit regex whitelist (e.g., `/^[a-zA-Z0-9_-]+$/`) before resolving or constructing file paths.
