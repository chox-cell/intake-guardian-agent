# Intake-Guardian Agent v1.0

Deterministic intake→workitems engine with:
- normalize + rules + dedupe
- sqlite storage
- append-only audit events
- plugin-ready export (createAgent)

## Run
cp .env.example .env
pnpm i
pnpm dev

## API
- GET  /api/health
- POST /api/intake
- GET  /api/workitems?tenantId=...&status=...
- GET  /api/workitems/:id?tenantId=...
- POST /api/workitems/:id/status
- POST /api/workitems/:id/owner
- GET  /api/workitems/:id/events?tenantId=...

## Smoke
pnpm dev (in one terminal)
pnpm smoke (in another)

## SSOT
See docs/SSOT-IntakeGuardian-Agent-v1.0.md
