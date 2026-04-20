## 2025-10-24 - [CSV Injection Vulnerability Mitigation]
**Vulnerability:** User-controlled input starting with =, +, -, or @ can trigger formula injection when exported to CSV.
**Learning:** Unsanitized user inputs in CSV exports can allow attackers to execute arbitrary spreadsheet formulas on the client machine.
**Prevention:** Always prepend a single quote to string fields starting with =, +, -, or @ in CSV export functions.
