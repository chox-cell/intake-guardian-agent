## 2025-03-08 - Fix Authorization Bypass in Stateless UI Auth Middleware
**Vulnerability:** The `uiAuth` middleware only checked for the existence of `tenantId` and `k` in the request query, but did not actually validate `k` against the tenant registry. This allowed any requester to provide a fake `k` and bypass authorization.
**Learning:** Middleware designed for stateless authentication must cryptographically or statefully verify the provided credentials against a source of truth, not just check that the fields exist in the request payload.
**Prevention:** Always use established credential verification utilities (like `verifyTenantKeyLocal`) when extracting and authorizing user or tenant details from request objects.
