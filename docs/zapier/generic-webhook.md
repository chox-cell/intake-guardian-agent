## Any Tool → Intake Guardian (Generic)

Trigger:
- Any app

Action:
- Webhooks by Zapier (POST)

Body:
{
  "source": "zapier",
  "type": "lead",
  "lead": {
    "fullName": "{{name}}",
    "email": "{{email}}",
    "raw": "{{bundle}}"
  }
}
