## 2025-03-07 - Fix Host Header Injection in URL Construction
**Vulnerability:** Host Header Injection via unvalidated `X-Forwarded-Proto` and `X-Forwarded-Host` headers in `baseUrl` functions.
**Learning:** Blindly trusting `X-Forwarded-*` or `Host` headers allows attackers to spoof the base URL, which can lead to phishing links in emails/UIs, SSRF, or cache poisoning.
**Prevention:** Validate `X-Forwarded-Proto` to explicitly allow only `http` or `https`. Validate `X-Forwarded-Host` and `Host` against a regex of safe characters (alphanumeric, dot, hyphen, and optional port) before using it to construct URLs.
