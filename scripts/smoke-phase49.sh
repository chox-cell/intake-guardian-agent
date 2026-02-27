#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Phase49 smoke (idempotent Phase48b + strict E2E)"

# 1) Phase48b idempotent: run twice
./scripts/oneshot-phase48b.sh
./scripts/oneshot-phase48b.sh
echo "OK: Phase48b idempotent check OK (twice)"

# 2) Strict E2E (must exist from Phase49)
if [ -x scripts/e2e-phase48.sh ]; then
  ./scripts/e2e-phase48.sh
else
  echo "FAIL: scripts/e2e-phase48.sh missing or not executable"
  exit 1
fi

echo "✅ Phase49 smoke OK"
