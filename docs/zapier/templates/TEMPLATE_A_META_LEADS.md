# Zapier Template — Meta Lead Ads → Ticket

Trigger:
Meta Lead Ads → New Lead

Action:
Webhooks by Zapier → POST

URL:
http://YOUR_SERVER/api/webhook/intake

Headers:
Content-Type: application/json

Body:
{
  "source": "zapier",
  "type": "lead",
  "lead": {
    "fullName": "{{First Name}} {{Last Name}}",
    "email": "{{Email}}",
    "phone": "{{Phone Number}}",
    "campaign": "{{Campaign Name}}"
  }
}
