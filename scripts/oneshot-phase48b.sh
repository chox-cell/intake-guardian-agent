#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Phase48b idempotent check (heuristics + E2E proof)"

# Heuristics (any strong signal means "already patched")
HITS=0

# 1) x-tenant-key header support inside server-side code OR api routing
if grep -R --line-number --quiet 'x-tenant-key' src 2>/dev/null; then
  echo "OK: found 'x-tenant-key' in src/"
  HITS=$((HITS+1))
fi

# 2) explicit demo tenant bypass condition (common pattern)
if grep -R --line-number --quiet 'tenantId.*demo' src 2>/dev/null; then
  echo "OK: found 'tenantId.*demo' pattern in src/"
  HITS=$((HITS+1))
fi

# 3) invalid_tenant_key string appears in src (often where bypass was injected)
if grep -R --line-number --quiet 'invalid_tenant_key' src 2>/dev/null; then
  echo "OK: found 'invalid_tenant_key' in src/"
  HITS=$((HITS+1))
fi

# 4) the E2E script itself uses x-tenant-key header (your Phase48b patched it earlier)
if [ -f scripts/e2e-phase48.sh ] && grep -n --quiet 'x-tenant-key' scripts/e2e-phase48.sh 2>/dev/null; then
  echo "OK: scripts/e2e-phase48.sh includes x-tenant-key header"
  HITS=$((HITS+1))
fi

# If we have strong enough hints, declare already patched (idempotent)
if [ "$HITS" -ge 2 ]; then
  echo "✅ Phase48b appears already applied (heuristics hits=$HITS)."
  exit 0
fi

# Otherwise, prove by running strict E2E (if available)
if [ -x scripts/e2e-phase48.sh ]; then
  echo "==> Heuristics inconclusive (hits=$HITS). Running strict E2E proof..."
  if ./scripts/e2e-phase48.sh >/tmp/phase48b_proof.log 2>&1; then
    echo "✅ Phase48b proven via E2E (green path)."
    exit 0
  fi
  echo "FAIL: E2E proof failed."
  echo "---- proof log tail ----"
  tail -n 60 /tmp/phase48b_proof.log || true
  echo
  echo "Hint: If you truly need to apply Phase48b patch again, re-run your Phase48b patcher oneshot."
  exit 1
fi

echo "FAIL: Could not prove Phase48b (no marker, heuristics hits=$HITS, and no executable scripts/e2e-phase48.sh)."
echo "Hint: re-run your Phase48b patcher oneshot, then retry."
exit 1
