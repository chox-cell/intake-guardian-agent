# Phase52 — Probe tenant-key source + strict E2E (no fallback)

## What changed
- Added `scripts/probe-phase52.sh`:
  - Shows which env vars are present (not values)
  - Lists candidate `./data` JSON files
  - Detects tenant key **source** + **length** only (never prints the key)
- Updated `scripts/e2e-phase48.sh`:
  - Detects demo key from:
    1) `TENANT_KEY_DEMO`
    2) `TENANT_KEYS` (JSON or `demo:key`)
    3) `./data/*.json` best-effort
  - **FAILS** if no key is found (no silent fallback)
  - Uses detected key in both places:
    - `x-tenant-key` header
    - `?k=` query param (URL encoded)
  - Strictly asserts:
    - HTTP 200/201
    - JSON: `ok=true`, `ticket.id` exists, `ticket.status=ready`

## Why
We kept seeing `invalid_tenant_key` because E2E was unintentionally using the **fallback** key.
This phase eliminates that failure mode and forces a real key source.

## Run
```bash
./scripts/probe-phase52.sh
./scripts/e2e-phase48.sh							MD
echo “✅ wrote docs/release/PHASE52_NOTE.md”

echo
echo “✅ Phase52 installed.”
echo “Run:”
echo “  ./scripts/probe-phase52.sh”
echo “  ./scripts/e2e-phase48.sh”
