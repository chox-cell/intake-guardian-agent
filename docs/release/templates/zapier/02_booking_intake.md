# Zapier — Template 02 (Booking → Ticket)

App: Webhooks by Zapier  
Event: POST

URL:
http://YOUR_BASE_URL/api/webhook/intake?tenantId=YOUR_TENANT_ID&k=YOUR_TENANT_KEY

Headers:
Content-Type: application/json

Body:
{
  "source": "zapier",
  "type": "booking",
  "booking": {
    "fullName": "John Smith",
    "email": "john@example.com",
    "event": "Discovery Call",
    "whenUtc": "2026-01-07T16:00:00Z",
    "notes": "Needs audit"
  }
}
