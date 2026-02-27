# Zapier — Template 01 (Lead → Ticket)

App: Webhooks by Zapier  
Event: POST

URL:
http://YOUR_BASE_URL/api/webhook/intake?tenantId=YOUR_TENANT_ID&k=YOUR_TENANT_KEY

Headers:
Content-Type: application/json

Body:
{
  "source": "zapier",
  "type": "lead",
  "lead": {
    "fullName": "Jane Doe",
    "email": "jane@example.com",
    "company": "Acme",
    "channel": "paid-ads",
    "message": "Interested in growth plan"
  }
}
