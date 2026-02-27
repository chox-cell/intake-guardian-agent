# Tenant Auth Contract (SSOT)

## Scope
Applies to:
- Webhook intake: `POST /api/webhook/intake`
- Any API/UI route that requires tenant auth

## Inputs
Tenant identity is provided by:
- `tenantId` (required): query `?tenantId=...` OR body `tenantId`

Tenant key is provided by (priority order):
1) query `?k=...`
2) header `x-tenant-key` (or `x-tenant`)
3) header `Authorization: Bearer <key>`
4) body `k` or `tenantKey`

## Status Codes (MUST)
- Missing tenantId → `400` `{ ok:false, error:"missing_tenant_id" }`
- Missing tenant key → `401` `{ ok:false, error:"missing_tenant_key" }`
- Invalid tenant key → `401` `{ ok:false, error:"invalid_tenant_key" }`

## Output Consistency
- JSON endpoints MUST return `error` as the code string above.
- HTML UI endpoints MUST render the same code (prefer `err.code`, fallback to `err.message`).

## Security Notes
- No dev bypass is allowed in production.
- Key comparison must be constant-time.
- Never log tenant keys.
