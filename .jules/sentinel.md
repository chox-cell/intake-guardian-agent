## 2024-05-18 - [Fix Plaintext Token Storage]
**Vulnerability:** Authentication tokens were being stored in plaintext in `tokens.json`.
**Learning:** Storing tokens in plaintext allows an attacker who reads the storage to impersonate users.
**Prevention:** Always store sensitive authentication tokens as strong cryptographic hashes (e.g. SHA-256) instead of plaintext.
