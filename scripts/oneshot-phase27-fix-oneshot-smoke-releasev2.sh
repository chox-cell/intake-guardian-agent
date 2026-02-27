#!/usr/bin/env bash
set -euo pipefail

say(){ echo "==> $*"; }
die(){ echo "❌ $*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -d "src" ] || die "src/ missing — run inside repo root"
[ -d "scripts" ] || die "scripts/ missing — run inside repo root"

ts() { date +"%Y%m%d_%H%M%S"; }

say "Phase27 OneShot (fix oneshot.sh cwd + add smoke-phase27 + release-pack v2) @ $ROOT"

# -------------------------
# Backup
# -------------------------
BAK="__bak_phase27_$(ts)"
mkdir -p "$BAK"
cp -R scripts "$BAK/" 2>/dev/null || true
cp -R src "$BAK/" 2>/dev/null || true
cp -f oneshot.sh "$BAK/" 2>/dev/null || true
cp -f package.json "$BAK/" 2>/dev/null || true
cp -f tsconfig.json "$BAK/" 2>/dev/null || true
say "backup -> $BAK"

# -------------------------
# Ensure tsconfig excludes backups
# -------------------------
if [ -f tsconfig.json ]; then
  node - <<'NODE'
const fs=require("fs");
const p="tsconfig.json";
let s=fs.readFileSync(p,"utf8");
let j=JSON.parse(s);

j.exclude = Array.isArray(j.exclude) ? j.exclude : [];
const add = (x)=>{ if(!j.exclude.includes(x)) j.exclude.push(x); };
add("__bak_*");
add("dist");
add("node_modules");
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
console.log("✅ patched tsconfig.json exclude");
NODE
fi

# -------------------------
# [1] Fix oneshot.sh to always run in repo root + mkdir -p for src/lib
# -------------------------
if [ -f oneshot.sh ]; then
  node - <<'NODE'
const fs=require("fs");
const p="oneshot.sh";
let s=fs.readFileSync(p,"utf8");

const header = `#!/usr/bin/env bash
set -euo pipefail

# Phase27 guard: always run in repo root
ROOT="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
[ -d "src" ] || { echo "ERROR: run inside repo root (src missing)"; exit 1; }
[ -d "scripts" ] || { echo "ERROR: run inside repo root (scripts missing)"; exit 1; }

# Make sure target dirs exist (Phase27)
mkdir -p src/lib src/api src/ui scripts dist data >/dev/null 2>&1 || true

say(){ echo "==> $*"; }
`;

if (!s.includes("Phase27 guard: always run in repo root")) {
  // Remove any bad early cd to ~/Projects
  s = s.replace(/^\s*cd\s+["']?\$?HOME\/Projects["']?\s*;?\s*$/m, "");
  s = s.replace(/^\s*cd\s+~\/Projects\s*;?\s*$/m, "");
  // Force shebang at top
  s = s.replace(/^#!.*\n/, "");
  s = header + "\n" + s;
}

fs.writeFileSync(p, s);
console.log("✅ patched oneshot.sh (repo-root guard + mkdir -p)");
NODE
else
  say "oneshot.sh not found — skipping patch"
fi

# -------------------------
# [2] Add scripts/smoke-phase27.sh (UI + extract key + webhook + verify + export)
# -------------------------
cat > scripts/smoke-phase27.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ $*" >&2; exit 1; }
say(){ echo "==> $*"; }

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-${ADMIN_KEY:-}}"

[ -n "${ADMIN_KEY:-}" ] || fail "missing ADMIN_KEY. Example: ADMIN_KEY=super_secret_admin_123 BASE_URL=$BASE_URL ./scripts/smoke-phase27.sh"

say "[0] health"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/health")"
echo "status=$code"
[ "$code" = "200" ] || fail "health not 200"

say "[1] /ui hidden (404 expected)"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/ui")"
echo "status=$code"
[ "$code" = "404" ] || fail "/ui should be hidden (404)"

say "[2] /ui/admin redirect (302 expected) + capture Location"
loc="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" \
  | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')"

[ -n "${loc:-}" ] || fail "no Location header from /ui/admin"
echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
[ -n "${TENANT_ID:-}" ] || fail "empty TENANT_ID"
[ -n "${TENANT_KEY:-}" ] || fail "empty TENANT_KEY"

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

say "[3] tickets should be 200"
tickets_url="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$tickets_url")"
echo "status=$code"
[ "$code" = "200" ] || fail "tickets not 200: $tickets_url"

say "[4] export.csv should be 200"
export_url="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$export_url")"
echo "status=$code"
[ "$code" = "200" ] || fail "export.csv not 200: $export_url"

say "[5] webhook intake should be 201 (creates/ dedupes ticket)"
# Use existing smoke-webhook.sh if present, else do direct POST
if [ -x "./scripts/smoke-webhook.sh" ]; then
  TENANT_ID="$TENANT_ID" TENANT_KEY="$TENANT_KEY" BASE_URL="$BASE_URL" ./scripts/smoke-webhook.sh
else
  body='{"source":"phase27_smoke","title":"IT Support Request","summary":"Cannot login","severity":"medium","email":"user@example.com","ts":"'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'"}'
  code="$(curl -sS -o /tmp/phase27_webhook.json -w '%{http_code}' \
    -H 'content-type: application/json' \
    -H "x-tenant-id: $TENANT_ID" \
    -H "x-tenant-key: $TENANT_KEY" \
    -d "$body" \
    "$BASE_URL/api/webhook/intake")"
  echo "status=$code"
  cat /tmp/phase27_webhook.json || true
  [ "$code" = "201" ] || fail "webhook not 201"
fi

say "[6] tickets page should still be 200 after webhook"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$tickets_url")"
echo "status=$code"
[ "$code" = "200" ] || fail "tickets not 200 after webhook"

echo
echo "✅ Phase27 smoke OK"
echo "Client UI:"
echo "  $tickets_url"
echo "Export CSV:"
echo "  $export_url"
BASH
chmod +x scripts/smoke-phase27.sh
say "✅ wrote scripts/smoke-phase27.sh"

# -------------------------
# [3] Release Pack v2 (update existing scripts/release-pack.sh)
# -------------------------
if [ -f scripts/release-pack.sh ]; then
  node - <<'NODE'
const fs=require("fs");
const p="scripts/release-pack.sh";
let s=fs.readFileSync(p,"utf8");

if (!s.includes("Release Pack v2")) {
  // Append v2 section safely at end
  s += `

# ============================================
# Release Pack v2 (Phase27)
# - includes smoke-phase27 + clear runbook
# ============================================
`;
}

const marker = "Release Pack v2 (Phase27)";
if (!s.includes(marker)) {
  s += `
echo
echo "==> Phase27 Runbook (embedded)"
cat > "$OUT_DIR/PHASE27_RUNBOOK.md" <<'MD'
# Phase27 — Webhook Intake → Ticket Pipeline

## Run
\`\`\`bash
cd ~/Projects/intake-guardian-agent
ADMIN_KEY=super_secret_admin_123 pnpm dev
\`\`\`

## Smoke (end-to-end)
\`\`\`bash
ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase27.sh
\`\`\`

## What you get
- Admin autolink: \`/ui/admin?admin=...\` → redirects to client link with \`tenantId\` + \`k\`
- Client UI: \`/ui/tickets?tenantId=...&k=...\`
- Export: \`/ui/export.csv?tenantId=...&k=...\`
- Webhook: \`POST /api/webhook/intake\` (x-tenant-id, x-tenant-key)

MD
echo "✅ wrote PHASE27_RUNBOOK.md"

# Include scripts in pack (they already are in full zip, but ensure docs present)
echo "==> Copy Phase27 runbook into assets"
mkdir -p "$OUT_DIR/assets"
cp -f "$OUT_DIR/PHASE27_RUNBOOK.md" "$OUT_DIR/assets/" || true
`;
}
fs.writeFileSync(p,s);
console.log("✅ patched scripts/release-pack.sh (v2 runbook + marker)");
NODE
else
  say "scripts/release-pack.sh not found — skipping patch"
fi

# -------------------------
# Typecheck (best effort)
# -------------------------
say "Typecheck"
if pnpm -s lint:types >/dev/null 2>&1; then
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase27 installed."
echo "Now:"
echo "  1) restart server: ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) smoke phase27:  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase27.sh"
echo "  3) release pack v2: ./scripts/release-pack.sh"
