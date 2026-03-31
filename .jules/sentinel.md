## 2025-01-26 - Open Redirect via Host Header
**Vulnerability:** Open redirect and potential credential leak via unvalidated Host/X-Forwarded-Host headers used to construct absolute URLs for the `location` header.
**Learning:** Using `req.headers.host` or `req.headers['x-forwarded-host']` to build redirect URLs without validation allows attackers to control the redirect destination and steal credentials from query strings.
**Prevention:** Use relative paths (e.g., `/path`) for internal redirects instead of absolute URLs.
