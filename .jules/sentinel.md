## 2025-01-20 - Plaintext Authentication Token Storage
**Vulnerability:** Authentication login link tokens were being stored in plaintext in the JSON data store (`tokens.json`).
**Learning:** Authentication tokens must be treated exactly like passwords. Storing them in plaintext means that an attacker with local file read access or a directory traversal vulnerability can extract them and trivially impersonate any user who has a valid, unexpired login link.
**Prevention:** Always apply a secure, one-way cryptographic hashing algorithm (like SHA-256) to authentication tokens or login links before persisting them to disk or a database. When verifying an incoming token, hash the provided input and perform a constant-time comparison against the stored hash.
