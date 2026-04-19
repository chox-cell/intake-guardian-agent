## 2024-05-24 - [CRITICAL] CSV Injection Vulnerability
**Vulnerability:** The application exports CSV files without sanitizing inputs that start with =, +, -, or @, leading to CSV/Formula Injection.
**Learning:** Spreadsheet applications execute formulas if cells begin with these characters, leading to code execution or data exfiltration.
**Prevention:** Sanitize CSV cell inputs by prepending a single quote (') to strings that start with formula-triggering characters (=, +, -, @).
