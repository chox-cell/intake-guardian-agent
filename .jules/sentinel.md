## 2024-05-02 - [CSV Formula Injection Fix]
**Vulnerability:** User input starting with `=`, `+`, `-`, or `@` in CSV exports can execute arbitrary commands in spreadsheet applications.
**Learning:** Even simple data exports can be an attack vector if user input is not sanitized according to the format's constraints.
**Prevention:** Always escape CSV fields that start with dangerous characters by prepending a single quote (`'`).
