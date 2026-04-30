## 2025-01-08 - Fix Plaintext Authentication Token Storage
**Vulnerability:** Authentication tokens used for generating magic links were being stored in plaintext in the `tokens.json` file.
**Learning:** Storing authentication tokens in plaintext is a security risk because if the database or file storage (`tokens.json`) is compromised, an attacker can use these tokens to impersonate users and bypass authentication. This codebase relies on token verification before provisioning or logging users in.
**Prevention:** Always hash sensitive authentication tokens before storing them. When verifying, hash the incoming token and compare it securely (using constant-time comparison) against the stored hash. We used a simple SHA-256 hash to address this.
