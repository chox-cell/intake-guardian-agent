# Intake-Guardian Platform — Task Plan (Golden Path → Enterprise)

## Global Guardrails (must pass every PR)
- pnpm typecheck
- pnpm integrity:verify
- No changes outside allowed paths unless approved:
  - src/** docs/** governance/** scripts/**

## Module A — Golden Flow Stabilization (MVP SSOT)
### Goal
Provision → Send Test Lead → Tickets visible → CSV has rows → Evidence ZIP non-empty and consistent.

### Must Have
- /api/admin/provision returns:
  - tenantId, k, links, webhook.easyUrl
- /api/webhook/easy accepts JSON body and forwards to intake SSOT
- /ui/tickets shows rows for tenantId+k
- /ui/export.csv includes tickets rows (not header-only)
- /ui/evidence.zip includes at minimum:
  - tickets.json
  - tickets.csv
  - README.txt
  - hashes.json (sha256 of files)
  - manifest.json reference (optional but recommended)

### DoD (Definition of Done)
- Golden test script passes (no guessing)
- Evidence ZIP generated for the SAME tenantId requested
- Completion report:
  - pnpm report:module GOLDEN_FLOW

## Module B — Zero-Tech Setup UI
### Goal
Client never sees “headers” or curl. Only copy buttons and guided steps.

### Must Have UI
- /ui/pilot:
  - Connect Form button
  - Choose provider: Google Forms / Typeform / Webflow / Zapier / Make / n8n
  - Shows:
    - Webhook URL (Copy)
    - Token (Copy)
    - Send Test Lead (one click)
    - Open Tickets (button)
    - Download Evidence ZIP (button)

### DoD
- Works for fresh provisioned tenant in < 60 seconds manual flow
- Copy matches backend requirements exactly
- Completion report: pnpm report:module ZERO_TECH_UI

## Module C — Integrations Templates Library
### Goal
Give user templates they can import into Zapier/Make/n8n.

### Deliverables
- docs/integrations/zapier.md (steps + screenshots placeholders)
- docs/integrations/make.json (exportable scenario)
- docs/integrations/n8n.json (workflow)
- docs/integrations/typeform.md
- docs/integrations/webflow.md
- docs/integrations/google-forms.md (via zapier/make)

### DoD
- Each doc contains:
  - required fields mapping → payload
  - how to paste webhook url/token
  - how to test
- Completion report: pnpm report:module INTEGRATIONS

## Module D — Enterprise Auth (HMAC + Replay Guard) [Optional but recommended]
### Goal
Support enterprise-grade verification without breaking zero-tech UX.

### Spec
- Accept:
  - x-tenant-key (token)
  - optional HMAC signature:
    - x-signature: sha256=hmac(secret, timestamp + "." + rawBody)
    - x-timestamp: unix seconds
- Replay guard:
  - reject if timestamp older than N minutes
  - store last N signatures per tenant (in memory or file) to prevent replay

### DoD
- Toggle with env:
  - HMAC_REQUIRED=true
- Docs updated
- Completion report: pnpm report:module ENTERPRISE_HMAC

## Module E — Governance + CI Gate
### Goal
No drift, no unauthorized changes.

### Deliverables
- ssot.md (master hash)
- governance/manifest.json (file hashes)
- scripts/verify-integrity.ts enforced in CI
- pre-commit or CI action:
  - typecheck
  - integrity:verify
  - fail if vendor lock changed

### DoD
- Any drift triggers CI failure
- Completion report: pnpm report:module GOVERNANCE
