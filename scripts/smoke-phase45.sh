#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

need(){ [ -s "$1" ] || { echo "FAIL missing/empty: $1"; exit 1; }; }

need src/lib/rulesets/paid_ads_v1.ts
need docs/release/PHASE45_WIRING_NOTE.md

if grep -R --line-number --quiet 'paid_ads.v1' src 2>/dev/null; then
  echo "OK: found 'paid_ads.v1' somewhere under src/"
else
  echo "FAIL: could not find 'paid_ads.v1' under src/"
  exit 1
fi

if grep -R --line-number --quiet 'decidePaidAdsV1' src 2>/dev/null; then
  echo "OK: found 'decidePaidAdsV1' somewhere under src/"
else
  echo "FAIL: could not find 'decidePaidAdsV1' under src/"
  exit 1
fi

echo "✅ Phase45 smoke OK"
