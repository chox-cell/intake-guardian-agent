## 2025-10-25 - Prevent CSV Injection
**Vulnerability:** Application exports data to CSV format without properly escaping characters that trigger formulas in spreadsheet applications, risking remote code execution or data exfiltration on the user's machine (CSV injection).
**Learning:** Found several different ad-hoc CSV serialization functions (`toCSV`, `toCsvCell`, `csvEscape`) in the codebase, none of which handled CSV formula injection. Need to apply sanitization broadly and consistently.
**Prevention:** Always prepend a single quote (`'`) to strings that begin with `=`, `+`, `-`, or `@` during CSV generation to force spreadsheet applications to treat the data as literal text.
