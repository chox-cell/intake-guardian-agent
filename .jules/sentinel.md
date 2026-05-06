## 2025-01-08 - CSV Injection Mitigation
**Vulnerability:** Multiple CSV export functions did not sanitize string fields, allowing formula injection if a user-supplied field started with `=`, `+`, `-`, or `@`.
**Learning:** CSV injection is a pervasive issue across multiple files when there is no centralized CSV builder that applies safety rules automatically.
**Prevention:** Implement a central CSV serialization utility and enforce its usage, or ensure all independent CSV sanitization functions prepend a single quote (`'`) to potentially executable fields.
