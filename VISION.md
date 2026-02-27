# Intake-Guardian Platform — Vision (Frame-Universe)

## Mission
Turn any inbound lead (forms/webhooks) into a trusted, deduped, auditable “Ticket + Evidence Pack” pipeline with zero-tech UX for clients and enterprise-grade integrity for operators.

## Who it's for
- Agencies / Sales teams / Support desks that receive leads from:
  - Google Forms, Typeform, Webflow forms
  - Zapier, Make, n8n webhooks
- Operators who need compliance-ready exports (CSV + evidence ZIP + audit trails).

## Core Value
1) **Zero-Tech Setup**
   - One link: Pilot
   - One button: Connect Form
   - Copy/Paste only: Webhook URL + Token
   - One click: Send Test Lead
   - Tickets appear instantly
   - Download Evidence ZIP (non-empty, verifiable)

2) **Trusted Outputs**
   - Tickets are deduped, structured, and exportable
   - Evidence ZIP is tamper-evident (hashes, manifest)
   - Governance tooling prevents agent drift (SSOT + master hash)

3) **Composable Agents**
   - Intake engine feeds downstream “agents” (triage, enrichment, routing, compliance, reporting)
   - Open-source agent frameworks can plug in, but our SSOT + integrity remains the guardrail.

## Non-Negotiables (System-19)
- SSOT for ticket storage and evidence contract
- Every milestone produces:
  - manifest.json
  - MASTER_HASH in ssot.md
  - verify-integrity.ts passes
  - COMPLETION_REPORT.pdf (contains hashes)

## End-State Product
- A client-facing UI that feels like: “Connect → Test → Done”
- An operator-facing control plane with:
  - tenants
  - webhooks
  - exports
  - integrity proofs
- Integrations library:
  - Zapier, Make, n8n templates
  - Webflow/Typeform recipes
  - Google Forms via Zapier/Make

## Definitions
- **Ticket**: normalized representation of an inbound lead/event
- **Evidence Pack**: zipped bundle containing ticket snapshot + exports + hashes + README
- **SSOT**: single source of truth for state, storage, and export rendering
- **Agent Drift**: unauthorized changes from autonomous agents; prevented via integrity checks
