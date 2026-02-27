# Phase54 — Resolve demo tenant key via registry link
- demo -> tenantId (tenant_registry.json)
- tenantId -> key (tenant_keys.json)
- No secrets printed; E2E strict.
Run:
  ./scripts/probe-phase52.sh
  ./scripts/e2e-phase48.sh
