# Zapier Template — Gmail → Ticket

Trigger:
Gmail → New Matching Email

Action:
Webhooks by Zapier → POST

URL:
http://YOUR_SERVER/api/webhook/intake

Headers:
Content-Type: application/json

Body:
{
  "source": "gmail",
  "type": "email",
  "lead": {
    "fullName": "{{From Name}}",
    "email": "{{From Email}}",
    "subject": "{{Subject}}",
    "message": "{{Body Plain}}"
  }
}
