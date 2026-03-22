## 2026-03-22 - CSV Formula Injection Prevention
**Vulnerability:** CSV export lacked escaping for characters (=, +, -, @), allowing Formula Injection if viewed in Excel.
**Learning:** Cell contents starting with formula characters can execute arbitrary code when exported to CSV.
**Prevention:** Prefix any cell starting with '=', '+', '-', or '@' with a single quote (''') to force plain text.