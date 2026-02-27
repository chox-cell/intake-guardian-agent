Zapier — Template 05 (Calendly Booking -> Ticket) — Paid Ads Agency Pack

App: Webhooks by Zapier
Event: POST

URL:
http://YOUR_BASE_URL/api/webhook/intake?tenantId=YOUR_TENANT_ID&k=YOUR_TENANT_KEY

Headers:
Content-Type: application/json

Body (JSON):
{
  "source": "zapier",
  "type": "booking",
  "channel": "paid-ads",
  "presetId": "paid_ads.v1",
  "booking": {
    "fullName": "Client Booking",
    "email": "owner@client.com",
    "event": "Paid Ads Audit",
    "whenUtc": "2026-01-08T16:00:00Z",
    "notes": "Client asks why ads not converting"
  },
  "tracking": {
    "hasPixel": false,
    "hasConversionApi": false,
    "hasGtm": false,
    "hasUtm": false,
    "hasThankYouPage": false
  }
}
