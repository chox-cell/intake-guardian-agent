# Phase51 — Fix macOS Bash incompatibility in E2E key autodetect

Fix:
- Removed `${var@Q}` (bash 4+) usage that breaks on macOS bash 3.2.
- Pass file path to node via argv (`node - "$file"`), eliminating quoting issues.

Result:
- Tenant key autodetect can read from:
  - TENANT_KEY_DEMO
  - TENANT_KEYS (JSON or demo:key)
  - ./data/*.json best-effort
  - fallback (last resort)
