#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

need(){ [ -s "$1" ] || { echo "FAIL missing/empty: $1"; exit 1; }; }

need src/lib/rulesets/paid_ads_v1.ts
need docs/release/templates/zapier/03_meta_lead_paid_ads.md
need docs/release/templates/zapier/04_google_lead_paid_ads.md
need docs/release/templates/zapier/05_calendly_booking_paid_ads.md
need docs/release/templates/n8n/paid_ads_webhook_example.json

if grep -R --line-number --quiet "paid_ads.v1" src/lib 2>/dev/null; then
  echo "OK: found 'paid_ads.v1' under src/lib"
else
  echo "WARN: could not find 'paid_ads.v1' under src/lib (preset registry patch may not have applied)."
  echo "      If your preset resolver lives elsewhere, wire: paid_ads.v1 -> decidePaidAdsV1"
fi

echo "✅ Phase44 smoke OK"
