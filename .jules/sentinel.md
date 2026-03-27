## 2024-05-24 - Fix CSV Injection (Formula Injection)
**Vulnerability:** The application was vulnerable to CSV Formula Injection in its export feature (`ticketsToCsv`). Fields were missing escaping for characters like `=`, `+`, `-`, and `@` that can execute code when opened in spreadsheet software like Excel.
**Learning:** It is easy to assume that standard CSV escaping (quotes and commas) is sufficient for safety. However, characters triggering formulas must also be neutralized by prepending a single quote (`'`).
**Prevention:** Ensure that any exported CSV fields reliably sanitize inputs starting with `=`, `+`, `-`, or `@` to neutralize potential formulas.
