## 2024-05-23 - [Path Traversal in Filesystem Operations]
**Vulnerability:** Unsanitized `tenantId` parameters used directly in `path.join()` or `path.resolve()` allowed arbitrary file read/write (Directory Traversal).
**Learning:** Bypassing strict regex validation on identifiers used for file paths risks exposing the underlying filesystem to malicious inputs like `../../`.
**Prevention:** Always validate path segments like `tenantId` using an allowlist regex (e.g., `/^[a-zA-Z0-9_-]+$/`) before constructing filesystem paths.
