# Phase53 — Detect demo tenant key from ./data (multi-shape) + strict E2E

## What changed
- `scripts/probe-phase52.sh`
  - Detects demo key from:
    1) `TENANT_KEY_DEMO`
    2) `TENANT_KEYS` (JSON or `demo:key` pairs)
    3) `./data/*.json` (multi-shape parser; limited scan)
  - Prints ONLY: source + length (never prints the key)

- `scripts/e2e-phase48.sh`
  - No fallback: fails if key cannot be detected
  - Uses key in BOTH:
    - `x-tenant-key` header
    - `?k=` query param (URL encoded)
  - Strict asserts:
    - HTTP 200/201
    - JSON: `ok=true`, `ticket.id` exists, `ticket.status=ready`

## Run
```bash
./scripts/smoke-phase53.sh						
MD												                                                                                                                                                  echo “✅ wrote docs/release/PHASE53_NOTE.md”
MD 
echo
echo “✅ Phase53 installed.”
echo “Run:”
echo “  ./scripts/smoke-phase53.sh”
