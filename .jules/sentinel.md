## 2024-05-24 - Path Traversal in Tenant Storage
**Vulnerability:** Found `tenantId` being used directly in file system paths (`path.resolve(..., tenantId)` and `path.join(..., tenantId)`) without validation, allowing directory traversal.
**Learning:** Even internal identifiers must be strictly validated before use in I/O operations if they might originate from external sources (e.g., query params).
**Prevention:** Enforce strict allowlist regex validation (e.g., `^[a-zA-Z0-9_-]+$`) on all dynamically generated file paths derived from input.
