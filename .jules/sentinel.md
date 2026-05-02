## 2025-01-20 - Plaintext Storage of Authentication Tokens
**Vulnerability:** Authentication tokens were stored in plaintext (`tokens.json`).
**Learning:** Storing authentication tokens in plaintext allows attackers who gain read access to the file system (e.g. via Path Traversal, LFI, or misconfigured backups) to steal active sessions and impersonate users.
**Prevention:** Always store authentication tokens as cryptographic hashes (e.g., SHA-256) instead of plaintext, ensuring that leaked data cannot be directly used to authenticate.
