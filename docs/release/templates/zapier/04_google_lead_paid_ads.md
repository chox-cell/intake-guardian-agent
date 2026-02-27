Zapier — Template 04 (Google Lead -> Ticket) — Paid Ads Agency Pack

App: Webhooks by Zapier
Event: POST

URL:
http://YOUR_BASE_URL/api/webhook/intake?tenantId=YOUR_TENANT_ID&k=YOUR_TENANT_KEY

Headers:
Content-Type: application/json

Body (JSON):
{
  "source": "zapier",
  "type": "lead",
  "channel": "google",
  "presetId": "paid_ads.v1",
  "lead": {
    "fullName": "Google Lead",
    "email": "lead2@client.com",
    "company": "Client Co"
  },
  "tracking": {
    "hasPixel": false,
    "hasConversionApi": false,
    "hasGtm": true,
    "hasUtm": true,
    "hasThankYouPage": false
  },
  "offer": { "hasClearOffer": false },
  "assets": { "hasLandingPage": true, "hasCreativeAssets": false },
  "notes": "Google lead intake"
}
