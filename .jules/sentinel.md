## 2024-05-15 - Fix Authorization Bypass in uiAuth
**Vulnerability:** The `uiAuth` middleware only checked for the presence of `tenantId` and `k` query parameters, without validating them against the tenant registry. This allowed any user to bypass authorization by providing arbitrary non-empty values.
**Learning:** Middleware intended for authorization must actively verify credentials against a trusted source of truth, not just check for their existence.
**Prevention:** Always use established verification functions (like `verifyTenantKeyLocal`) in authentication/authorization middleware. Never trust user input without cryptographic or database validation.
