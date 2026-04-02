## 2026-01-10 - [Host Header Injection in URL Construction]
**Vulnerability:** URL construction relies on untrusted `Host` and `X-Forwarded-Host` headers without validation.
**Learning:** Relying on request headers for URL construction can lead to Host Header Injection, enabling phishing, password reset poisoning, or cache poisoning.
**Prevention:** Always use trusted configurations like `process.env.APP_BASE_URL` when available. If fallback to headers is necessary, rigorously validate the host string against a strict regex (e.g., `^[a-zA-Z0-9.-]+(:\d+)?$`).
