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

