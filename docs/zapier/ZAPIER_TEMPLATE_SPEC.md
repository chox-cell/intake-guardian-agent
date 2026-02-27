# Zapier Template Spec

Trigger:
- Typeform/Calendly/Meta Lead Ads/Website form

Action:
- Webhooks by Zapier → POST
- URL: ${BASE_URL}/api/webhook/intake
- Body: JSON (see payload examples)

Expected:
- HTTP 201
- Ticket appears in /ui/tickets
- Export CSV includes the ticket
- Evidence ZIP contains ticket snapshot
