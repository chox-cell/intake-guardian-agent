## Sentinel Journal

## 2024-10-24 - [CRITICAL] Host Header Injection
**Vulnerability:** The application was vulnerable to Host Header Injection due to blindly trusting the `Host` or `X-Forwarded-Host` HTTP headers to construct absolute URLs used in redirects and emails.
**Learning:** Request headers can be easily spoofed by malicious clients. Constructing absolute URLs from untrusted headers without validation allows an attacker to manipulate the domains used in outgoing emails or redirects, potentially leading to phishing or credential theft. When mitigating this, ensure that you don't inadvertently remove explicit base URL logic (`APP_BASE_URL`) which is critical for handling cross-domain configurations.
**Prevention:** Strictly validate the `Host` or `X-Forwarded-Host` headers against a whitelist or a strict regular expression (e.g., `/^[a-zA-Z0-9.-]+(:\d+)?$/`) before using them to construct URLs, falling back to a safe default if validation fails. Do not blindly switch to relative redirects if the application relies on an explicitly configured base URL.
