## 2025-05-19 - Plaintext Token Storage
**Vulnerability:** Authentication tokens were stored in plaintext in tokens.json.
**Learning:** Storing tokens without hashing enables lateral movement on filesystem compromise.
**Prevention:** Always hash authentication tokens using SHA-256 before storage.
