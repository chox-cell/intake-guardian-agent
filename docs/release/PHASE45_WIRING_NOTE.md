Phase45 — Wiring Note (paid_ads.v1)

Goal:
- Ensure presetId "paid_ads.v1" resolves to decidePaidAdsV1.

What Phase45 does:
- Scans src/ for the most likely preset resolver.
- Attempts to insert:
  - import { decidePaidAdsV1 } from "./rulesets/paid_ads_v1";
  - mapping for "paid_ads.v1"

If you still see a warning:
- Search manually for your resolver:
  - grep -R "it_support.v1" -n src
  - grep -R "presetId" -n src
Then wire:
- "paid_ads.v1" -> decidePaidAdsV1
