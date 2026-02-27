# Phase50 — Fix E2E Tenant Key Autodetect (Strict)

Why:
- E2E was failing with `401 invalid_tenant_key` because the script hardcoded a key
  that did not match the configured tenant key in the local runtime.

What changed:
- `scripts/e2e-phase48.sh` now auto-detects the tenant key using:
  1) TENANT_KEY_DEMO env
  2) TENANT_KEYS env (JSON or "demo:key" pairs)
  3) local data files under ./data (best-effort)
  4) fallback (dev_admin_key_123) as last resort

Strict assertions:
- Requires HTTP 200/201
- Requires JSON: ok=true, ticket.id exists, ticket.status=ready
