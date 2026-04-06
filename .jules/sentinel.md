## 2025-04-06 - [CRITICAL] Plaintext Storage of Authentication Tokens
**Vulnerability:** The application was storing sensitive authentication tokens in plaintext within `tokens.json` in the `/request-link` route (`src/api/auth.ts`).
**Learning:** Storing tokens in plaintext makes the application highly vulnerable to data breaches; if the filesystem or server is compromised, attackers gain immediate access to user sessions and accounts. This likely happened due to a lack of awareness or oversight in securely handling temporary tokens before verifying them.
**Prevention:** Always hash authentication tokens using a strong cryptographic hash function (like SHA-256) before storing them, and compare the hash of the provided token against the stored hash during verification.
