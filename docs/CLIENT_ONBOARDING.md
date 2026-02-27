# Intake Guardian — Client Onboarding (5 minutes)

This system turns leads into:
- Deduplicated tickets
- CSV export
- Evidence ZIP (proof)

## What client receives
ONE link only:
- Tickets
- Export CSV
- Evidence ZIP

No login. No dashboard complexity.

## Step 1 — Generate client link
Run server:
ADMIN_KEY=YOUR_ADMIN_KEY pnpm dev

Open:
http://127.0.0.1:7090/ui/admin?adminKey=YOUR_ADMIN_KEY

You will be redirected to:
 /ui/tickets?tenantId=XXX&k=YYY

Send this FULL URL to the client.

tenantId = workspace  
k = access key (private)

## Step 2 — Zapier setup
Zapier → Webhooks by Zapier → POST

URL:
http://YOUR_SERVER/api/webhook/intake

Headers:
Content-Type: application/json

Body example:
{
  "source": "zapier",
  "type": "lead",
  "lead": {
    "fullName": "Jane Doe",
    "email": "jane@example.com",
    "message": "Interested"
  }
}

Result:
- Ticket appears instantly
- Duplicate payloads are merged (no spam)

## Step 3 — Proof delivery
Client can download:
- Export CSV
- Evidence ZIP

Troubleshooting:
- /health returns ok
- tenantId and k exist in URL
- POST body is valid JSON
