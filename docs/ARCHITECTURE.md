# Architecture — Intake-Guardian Agent v1.0

## Modules
- adapters: channel adapters (future expansion)
- core: normalize/rules/dedupe/transitions
- presets: vertical configs (it_support.v1)
- store: storage interface + sqlite implementation + memory fallback
- audit: append-only event logger
- api: HTTP routes
- plugin: createAgent() for embedding into any host app
- server: standalone HTTP service

## Flow
InboundEvent → Normalize → Rules → Dedupe → Store WorkItem → Append Audit → Respond
