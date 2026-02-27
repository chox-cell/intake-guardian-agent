# Phase49 — Idempotent Phase48b + Strict E2E

What changed:
- Added `scripts/oneshot-phase48b.sh`:
  - If Phase48b marker exists in `src/`, it returns OK (idempotent).
  - No more noisy "FAIL: already_patched".
- Hardened `scripts/e2e-phase48.sh`:
  - Requires /health ready
  - POSTs paid_ads.v1 JSON with x-tenant-key header
  - Asserts HTTP 200/201
  - Parses JSON and asserts: ok=true, ticket.id exists, ticket.status=ready
- Added `scripts/smoke-phase49.sh`:
  - Runs oneshot-phase48b twice
  - Runs strict E2E

Security boundary:
- This phase does NOT widen bypass scope. It only makes already-patched state behave as success and tightens E2E assertions.
