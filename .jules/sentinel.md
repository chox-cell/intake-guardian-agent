## 2026-05-09 - [CSV Injection Prevention]
**Vulnerability:** CSV exports across multiple endpoints did not sanitize fields starting with formula characters.
**Learning:** Spreadsheets evaluate cells starting with `=` `+` `-` `@` as formulas, enabling code execution risks.
**Prevention:** Prepend a single quote (`'`) to these values so spreadsheets interpret them as text.
