Zapier — Template 03 (Meta Lead -> Ticket) — Paid Ads Agency Pack

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
  "channel": "meta",
  "presetId": "paid_ads.v1",
  "lead": {
    "fullName": "Meta Lead",
    "email": "lead@client.com",
    "company": "Client Co"
  },
  "tracking": {
    "hasPixel": true,
    "hasConversionApi": false,
    "hasGtm": true,
    "hasUtm": false,
    "hasThankYouPage": true
  },
  "offer": { "hasClearOffer": true },
  "assets": { "hasLandingPage": true, "hasCreativeAssets": true },
  "notes": "Meta lead intake"
}
