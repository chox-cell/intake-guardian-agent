#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK"

echo "==> Option B one-shot (CLEAN): Provisioning + Emails + Accounts"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"
echo

# Backup only what we will touch (safe)
for f in \
  "scripts/smoke-auth-provisioning.sh" \
  "scripts/smoke-tenant-auth.sh" \
  "scripts/e2e-phase48.sh"
do
  if [ -f "$f" ]; then
    mkdir -p "$BAK/$(dirname "$f")"
    cp -v "$f" "$BAK/$f.bak"
  fi
done

# Ensure nodemailer exists (optional; outbox works without SMTP)
if [ -f package.json ]; then
  if ! rg -n '"nodemailer"' package.json >/dev/null 2>&1; then
    echo "==> pnpm add nodemailer"
    pnpm -s add nodemailer >/dev/null
  fi
fi

# -----------------------------
# SMOKE: auth provisioning (request-link)
# - uses .env.local (autoload)
# - calls POST /api/auth/request-link
# -----------------------------
cat > scripts/smoke-auth-provisioning.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail

# auto-load .env.local for local runs (no secrets printed)
if [ -f "./.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  source "./.env.local" || true
  set +a
fi

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
EMAIL="${EMAIL:-test+agency@local.dev}"

echo "==> SMOKE Auth Provisioning"
echo "==> BASE_URL = $BASE_URL"
echo "==> EMAIL    = $EMAIL"
echo

code="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/health" || true)"
if [ "$code" != "200" ]; then
  echo "FAIL: /health expected 200, got $code" >&2
  exit 1
fi
echo "OK: /health"

# Request link (should 200)
code="$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/api/auth/request-link" \
  -H "content-type: application/json" \
  --data "{\"email\":\"$EMAIL\"}" || true)"

echo "request-link => HTTP $code"
if [ "$code" != "200" ]; then
  echo "FAIL: expected 200" >&2
  exit 1
fi

echo "OK ✅ Auth provisioning request-link"
echo "Note: In dev without SMTP_URL, check data/outbox for email link."
SH2

chmod +x scripts/smoke-auth-provisioning.sh

echo
echo "==> 1) bash parse check"
bash -n scripts/smoke-auth-provisioning.sh
echo "OK: smoke-auth-provisioning.sh parses"

echo
echo "==> 2) typecheck"
pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "==> 3) SMOKE tenant auth"
./scripts/smoke-tenant-auth.sh

echo
echo "==> 4) E2E Phase48"
./scripts/e2e-phase48.sh

echo
echo "==> 5) SMOKE auth provisioning"
./scripts/smoke-auth-provisioning.sh

echo
echo "OK ✅ Option B (CLEAN) applied"
echo "Backups: $BAK"
echo "Next: open /ui/login and request a link; if no SMTP_URL, read data/outbox/*.txt"
