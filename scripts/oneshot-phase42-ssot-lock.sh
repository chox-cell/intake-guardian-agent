#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Phase42 OneShot (SSOT Lock) @ $ROOT"
[ -d src ] || { echo "ERROR: run inside repo root (src missing)"; exit 1; }
mkdir -p docs scripts

STAMP="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase42_${STAMP}"
mkdir -p "$BAK"
cp -R docs scripts package.json tsconfig.json "$BAK" 2>/dev/null || true
echo "✅ backup -> $BAK"

# -------------------------
# NEW FILE: docs/SSOT_LOCK.md
# -------------------------
cat > docs/SSOT_LOCK.md <<'MD'
# Decision Cover™ — SSOT LOCK (v1)
**Status:** LOCKED ✅  
**Rule:** If something is not written here, it does not exist.  
**Core line:** _“If you must decide, decide with proof.”_

---

## 0) Purpose
Decision Cover™ turns messy intake (forms/webhooks/email) into:
- a documented **Decision**
- a downloadable **Evidence Pack** (ZIP)
- exports you can share with clients, auditors, or internal teams

We are **not** a prediction engine. We are a **proof-first decision cover**.

---

## 1) Product Identity
**Name:** Decision Cover™  
**Category:** Agency Decision Cover (Proof & Evidence automation)  
**Customer first:** Agencies (Paid Ads, SEO, Web Dev, Creatives, Ops)  
**Second:** Legal/Medical Shield (higher value, slower sales)  
**Third:** Generic Decision Engine (platform)

**Brand tone:** calm, precise, transparent, no hype.

---

## 2) Non-negotiables (System Rules)
1. **Proof > Promises:** every decision must show inputs and evidence.
2. **Vendor-neutral:** works with Zapier / n8n / Make / custom webhooks.
3. **No secrets in UI:** keys never rendered; link-token is demo-only.
4. **Deterministic output:** same inputs → same decision (for a given ruleset).
5. **Export always works:** CSV/ZIP must be available.
6. **Simple install:** single env + run + connect webhook.
7. **No scope creep:** only what’s in SSOT is “shipped”.

---

## 3) Canonical Journey (Clean Pipeline)
**1) Intake → 2) Normalize → 3) Decide → 4) Evidence → 5) Export → 6) Share**

### 3.1 Intake
Sources:
- Webhooks (Zapier/n8n/Make)
- Forms (Typeform/Tally/Google Forms via webhook)
- Calendly booking payload
- Optional: email forwarder (later)

Output: Ticket created (dedupe window applies).

### 3.2 Normalize
- Extract fields
- Tag/type
- Dedupe (window-based)
- Create normalized record

### 3.3 Decide
Ruleset produces:
- Tier (Green/Yellow/Red/Purple)
- Score (0–100)
- Reason (written)
- Recommended actions (written)

### 3.4 Evidence
Evidence Pack contains:
- decision.json
- inputs.json
- timeline.json (events)
- export.csv (optional mirror)
- integrity.txt (hashes + notes)

### 3.5 Export
- CSV (simple sharing)
- ZIP (client/auditor pack)

### 3.6 Share
- Client-safe view via link-token (tenantId+k in demo)
- Admin view via admin key

---

## 4) Current Local Endpoints (Contract)
Health:
- `GET /health` → 200

Admin redirect:
- `GET /ui/admin?admin=ADMIN_KEY` → 302 → `/ui/tickets?tenantId=...&k=...`

UI pages:
- `GET /ui/tickets?tenantId=...&k=...` → 200 (themed)
- `GET /ui/setup?tenantId=...&k=...` → 200 (themed)
- `GET /ui/decisions?tenantId=...&k=...` → 200 (themed)

Exports:
- `GET /ui/export.csv?tenantId=...&k=...` → 200
- `GET /ui/evidence.zip?tenantId=...&k=...` → 200/404 (depending on readiness)

Intake webhook:
- `POST /api/webhook/intake?tenantId=...&k=...` (exact path in repo)

---

## 5) Data Model (Minimum)
**Ticket**
- id, createdAt, source, type
- lead/company/contact fields
- rawPayload (stored)
- normalized fields
- dedupeKey

**Decision**
- id, ticketId
- rulesetId, score, tier
- reason, recommendedActions[]
- signals[] (transparent inputs)
- createdAt

**Evidence Pack**
- packId, decisionId, files[]
- hashes (sha256), generatedAt

---

## 6) Security & Integrity Notes
- ADMIN_KEY protects admin-only redirect route.
- Tenant key in URL is treated as **link-token for demo**; production can replace with signed tokens.
- No secrets should ever be embedded in UI HTML.
- Evidence pack should include hashes to make it tamper-evident.

---

## 7) Release Gate
A build is “shippable” only if:
- health 200
- tickets 200
- setup 200
- decisions 200
- export.csv 200
- evidence.zip returns 200 OR documented as 404 with reason
- smoke scripts pass

---

## 8) Roadmap (Locked)
### Phase42 — SSOT Lock ✅
- Lock SSOT docs and product boundaries (this file + boundaries)

### Phase43 — Installer Pack
- `release-pack` produces a clean zip
- includes docs + zapier/n8n templates + smoke instructions

### Phase44 — Paid Ads Agency Pack
- presets: paid_ads.v1
- templates: Meta lead / Google lead / Calendly booking
- decision labels: refund / pause / escalate / ask-proof

### Phase45 — Checkout + Landing (separate repo)
- v0.dev → GitHub → Vercel
- Gumroad buy button + after-purchase install

---

## 9) SSOT Change Policy
To change SSOT:
- Create `docs/SSOT_CHANGES.md` entry (date, reason, impact)
- Bump SSOT version (v1 → v1.1)
- Never “silent edit” without logging

MD
echo "✅ wrote docs/SSOT_LOCK.md"

# -------------------------
# NEW FILE: docs/PRODUCT_BOUNDARIES.md
# -------------------------
cat > docs/PRODUCT_BOUNDARIES.md <<'MD'
# Decision Cover™ — Product Boundaries (LOCKED v1)

## What we are
A proof-first decision cover:
- intake → normalize → decide → evidence → export
- designed to help agencies justify decisions with client-safe proof packs

## What we are NOT
- Not a “guaranteed outcome” engine
- Not a predictive AI oracle
- Not a CRM replacement
- Not a full ticketing platform (we keep it minimal)
- Not storing secrets in UI

## Allowed claims (safe)
- “Documented decisions with evidence you can export”
- “Vendor-neutral intake via webhooks”
- “Transparent signals and written reasons”
- “Evidence ZIP for client/auditor sharing”

## Forbidden claims
- “We guarantee performance”
- “We predict outcomes”
- “We ensure compliance by default”
- Any medical/legal promises without a professional scope

## Privacy posture
- Collect only what is needed
- Keep raw payloads for traceability (tenant-scoped)
- Use hashes in evidence packs when possible
MD
echo "✅ wrote docs/PRODUCT_BOUNDARIES.md"

# -------------------------
# NEW FILE: docs/SSOT_CHANGES.md
# -------------------------
cat > docs/SSOT_CHANGES.md <<'MD'
# SSOT Changes Log

## v1 — 2026-01-07
- Created initial SSOT lock + boundaries.
- Defined canonical journey, endpoints contract, data model, release gate.
MD
echo "✅ wrote docs/SSOT_CHANGES.md"

# -------------------------
# Update/Create docs/README.md pointer
# -------------------------
cat > docs/README.md <<'MD'
# Docs Index (Decision Cover™)

**SSOT (LOCKED):**
- `docs/SSOT_LOCK.md`
- `docs/PRODUCT_BOUNDARIES.md`
- `docs/SSOT_CHANGES.md`

If it’s not in SSOT, it’s not shipped.
MD
echo "✅ wrote docs/README.md"

# -------------------------
# Smoke Phase42 (just verifies SSOT files exist + readable)
# -------------------------
cat > scripts/smoke-phase42.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

need(){ [ -s "$1" ] || { echo "FAIL missing/empty: $1"; exit 1; }; }

need docs/SSOT_LOCK.md
need docs/PRODUCT_BOUNDARIES.md
need docs/SSOT_CHANGES.md
need docs/README.md

echo "✅ Phase42 smoke OK (SSOT files present)"
