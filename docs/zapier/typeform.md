## Typeform → Intake Guardian

Trigger:
- App: Typeform
- Event: New Entry

Action:
- Webhooks by Zapier (POST)

Body:
{
  "source": "typeform",
  "type": "lead",
  "lead": {
    "fullName": "{{name}}",
    "email": "{{email}}",
    "answers": "{{all_answers}}"
  }
}
