# Sentinel Security Journal

## 2025-05-18 - Prevent CSV Formula Injection in Ticket Export
**Vulnerability:** CSV Formula Injection (also known as CSV Injection or Macro Injection). The application exported tickets to CSV without escaping fields that started with execution characters (`=`, `+`, `-`, `@`).
**Learning:** If user-controlled data is exported unescaped into a CSV, opening the file in applications like Microsoft Excel or Google Sheets could cause the payload to be evaluated as a formula. This could lead to local command execution or data exfiltration.
**Prevention:** Always inspect output fields prior to formatting them as a CSV, and prepend a single quote (`'`) to any string that begins with `=`, `+`, `-`, or `@`.
