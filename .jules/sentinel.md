## 2026-03-14 - [CSV Injection Vulnerability in Ticket Export]
**Vulnerability:** The `ticketsToCsv` function in `src/lib/ticket-store.ts` allowed user-controlled fields (like `title` or `type`) to start with formula characters (`=`, `+`, `-`, `@`), which could result in arbitrary formula execution when the CSV is opened in spreadsheet software like Microsoft Excel or Google Sheets.
**Learning:** Even internal admin tools like CSV exporters can be vectors for attacks if the content originated from untrusted sources (e.g., webhook intake payloads).
**Prevention:** All user-controlled fields in CSV outputs must be checked for formula-initiating characters (`=`, `+`, `-`, `@`) and prefixed with a safe character (like `'`) to neutralize formula interpretation.
