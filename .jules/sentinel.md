## 2024-05-20 - Plaintext Tokens and Open Redirect in Auth
**Vulnerability:** Auth tokens were stored in plaintext in `tokens.json`, and redirect URLs used host headers without strict validation.
**Learning:** Storing plaintext tokens allows full account takeover if file system read access is compromised. Using `x-forwarded-host` for redirects leads to Open Redirect vulnerabilities.
**Prevention:** Always store cryptographic hashes (e.g., SHA-256) of authentication tokens. Use relative paths for internal application redirects.
