# Phase48 — Fix Auth + E2E Green Path

What changed:
- Added a **dev-only** bypass to unblock local E2E:
  - If `NODE_ENV=development` AND `tenantId=demo` AND `k == ADMIN_KEY` → allow webhook.
- Added a GET helper response (405) so opening the webhook in the browser explains "POST-only".
- Added `scripts/e2e-phase48.sh` which:
  - starts server
  - waits health
  - POSTs a valid paid_ads.v1 payload
  - asserts 200/201

Security:
- Bypass is **dev-only** and scoped to `tenantId=demo`.
- No secrets are returned in the GET helper response.
