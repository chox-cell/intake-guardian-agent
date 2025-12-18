# SSOT-IntakeGuardian-Agent-v1.0 (LOCKED)

## Purpose
Convert inbound messages (email/whatsapp/form/api) into deterministic WorkItems with audit + dedupe.
NO LLM dependency in v1.

## Scope (locked)
- Intake (email|whatsapp|form|api)
- Normalize
- Rules Engine (deterministic)
- Dedupe
- Store WorkItem
- Append-only Audit Events
- Board API (list/update/search)

## Non-goals (v1)
- Full UI
- Infinite customization workflows
- AI-driven core decisions
- Billing/marketplace

## Contracts
InboundEvent -> WorkItem (+ AuditEvent)

States (fixed):
new | triage | in_progress | waiting | resolved | closed

Priority (fixed):
low | normal | high | critical

## Guardian Rules (enforced)
- Any feature outside scope is rejected.
- No schema drift before first paid customer.
- LLM is optional plugin only, never required for classification/priority/SLA.
- Audit is append-only.
