## Meta Lead Ads → Intake Guardian

Trigger:
- App: Facebook Lead Ads
- Event: New Lead

Action:
- App: Webhooks by Zapier
- Event: POST

URL:
{{BASE_URL}}/api/webhook/intake

Headers:
Content-Type: application/json

Body:
{
  "source": "meta",
  "type": "lead",
  "lead": {
    "fullName": "{{full_name}}",
    "email": "{{email}}",
    "phone": "{{phone_number}}",
    "campaign": "{{ad_name}}"
  }
}
