#!/usr/bin/env bash
set -euo pipefail

# Release Pack Generator (Gumroad-ready)
# Output: dist/intake-guardian-agent/<stamp>/*
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STAMP="${1:-$(date +%Y-%m-%d_%H%M)}"
OUT="dist/intake-guardian-agent/${STAMP}"
PROD="intake-guardian-agent-v1"

mkdir -p "$OUT/assets"

echo "==> Build meta"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || true)"
NODE_V="$(node -v 2>/dev/null || true)"
PNPM_V="$(pnpm -v 2>/dev/null || true)"

cat > "$OUT/publish.meta.json" <<JSON
{
  "product": "${PROD}",
  "stamp": "${STAMP}",
  "git": "${GIT_SHA}",
  "node": "${NODE_V}",
  "pnpm": "${PNPM_V}",
  "ports": { "default": 7090 },
  "run": "ADMIN_KEY=super_secret_admin_123 pnpm dev"
}
JSON

echo "==> Gumroad copy"
cat > "$OUT/GUMROAD_COPY_READY.txt" <<'TXT'
TITLE:
Intake-Guardian v1 — Unified Client Intake + Tickets + CSV Proof Export (Self-Hosted)

ONE-LINE:
Turn messy client requests into one inbox with shareable tenant links + proof export.

WHO IT’S FOR:
- Agencies (leads + onboarding + support)
- IT support (internal tickets)
- Small ops teams (requests from email/forms/DMs)

WHAT YOU GET:
- Self-hosted app (Node/Express) with a clean Tickets UI
- Admin autolink → client link generator per tenant
- CSV export for proof/reporting
- Demo ticket generator (instant value)
- Scripts: smoke test + demo key generator
- Checksums for integrity

HOW IT WORKS (60s):
1) Run locally: ADMIN_KEY=super_secret_admin_123 pnpm dev
2) Open: http://127.0.0.1:7090/ui/admin?admin=super_secret_admin_123
3) You’ll be redirected to a client link (/ui/tickets?...&k=...)
4) Share that link with your client/team
5) Export CSV anytime

NOTES:
- Don’t expose ADMIN_KEY to clients.
- This pack is v1 (local file storage). Next releases can add Supabase + webhooks.

LICENSE:
Single buyer license (your company/team). No resale.

FAQ:
Q: Does it need a database?
A: No (v1 uses local storage). You can add DB later.

Q: Can I host it?
A: Yes. It’s a standard Node app.
TXT

echo "==> Checklist"
cat > "$OUT/PUBLISH_CHECKLIST.md" <<'MD'
# Intake-Guardian — Publish Checklist (Gumroad)

## Pre-flight
- [ ] `pnpm -s lint:types`
- [ ] `ADMIN_KEY=super_secret_admin_123 pnpm dev`
- [ ] `ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh`
- [ ] Open landing: http://127.0.0.1:7090/
- [ ] Open admin: http://127.0.0.1:7090/ui/admin?admin=super_secret_admin_123
- [ ] Create demo ticket inside Tickets UI
- [ ] Export CSV works

## Gumroad Upload
Upload:
- `intake-guardian-agent-v1.zip` (full)
- `intake-guardian-agent-v1_SAMPLE.zip` (sample)
- `cover.svg` (or convert to PNG)
Copy/paste:
- `GUMROAD_COPY_READY.txt`

## Screenshots (recommended)
- Landing page
- Tickets UI with one demo ticket
- Export CSV download
MD

echo "==> Cover (SVG)"
cat > "$OUT/cover.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1000" viewBox="0 0 1600 1000">
  <defs>
    <radialGradient id="bg" cx="30%" cy="20%" r="90%">
      <stop offset="0%" stop-color="#0b1633"/>
      <stop offset="65%" stop-color="#05070c"/>
    </radialGradient>
    <linearGradient id="stroke" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#60a5fa" stop-opacity="0.6"/>
      <stop offset="100%" stop-color="#22c55e" stop-opacity="0.5"/>
    </linearGradient>
  </defs>
  <rect width="1600" height="1000" fill="url(#bg)"/>
  <rect x="120" y="140" width="1360" height="720" rx="36" fill="rgba(17,24,39,0.55)" stroke="url(#stroke)" stroke-width="2"/>
  <text x="180" y="270" font-family="ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial" font-size="74" fill="#e5e7eb" font-weight="900">Intake-Guardian v1</text>
  <text x="180" y="340" font-family="ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial" font-size="30" fill="#a7b0c0" font-weight="700">
    Unified client intake • Tickets inbox • Tenant links • CSV proof export
  </text>

  <g font-family="ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace" font-size="22" fill="#cbd5e1">
    <text x="180" y="440">✔ Shareable tenant link (no account UX)</text>
    <text x="180" y="485">✔ Demo ticket button (instant value)</text>
    <text x="180" y="530">✔ Export CSV for proof/reporting</text>
    <text x="180" y="575">✔ Self-hosted (Node/Express)</text>
  </g>

  <text x="180" y="800" font-family="ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial" font-size="22" fill="#9ca3af">
    Built for agencies & IT teams • System-19 minded • No secrets shipped
  </text>
</svg>
SVG

echo "==> Zip full product"
TMP_FULL="$(mktemp -d)"
mkdir -p "$TMP_FULL/$PROD"
rsync -a \
  --exclude "__bak_*" \
  --exclude "node_modules" \
  --exclude "dist" \
  --exclude ".git" \
  ./ "$TMP_FULL/$PROD/" >/dev/null

( cd "$TMP_FULL" && zip -qr "${PROD}.zip" "$PROD" )
mv "$TMP_FULL/${PROD}.zip" "$OUT/${PROD}.zip"
rm -rf "$TMP_FULL"

echo "==> Zip sample (no source, just docs + screenshots placeholder)"
TMP_S="$(mktemp -d)"
mkdir -p "$TMP_S/$PROD"
cp "$OUT/GUMROAD_COPY_READY.txt" "$TMP_S/$PROD/"
cp "$OUT/PUBLISH_CHECKLIST.md" "$TMP_S/$PROD/"
cp "$OUT/cover.svg" "$TMP_S/$PROD/"
cat > "$TMP_S/$PROD/README_SAMPLE.md" <<'MD'
# Intake-Guardian SAMPLE

This sample contains:
- Gumroad copy
- Publish checklist
- Cover SVG

To run the full app, download the full ZIP (not the sample).
MD

( cd "$TMP_S" && zip -qr "${PROD}_SAMPLE.zip" "$PROD" )
mv "$TMP_S/${PROD}_SAMPLE.zip" "$OUT/${PROD}_SAMPLE.zip"
rm -rf "$TMP_S"

echo "==> Checksums"
node - <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const path = require("path");

const out = process.argv[1];
NODE
# Use shasum if available
if command -v shasum >/dev/null 2>&1; then
  (cd "$OUT" && shasum -a 256 *.zip cover.svg publish.meta.json GUMROAD_COPY_READY.txt PUBLISH_CHECKLIST.md > checksums.sha256.txt)
  node - <<NODE
const fs=require("fs");
const p="${OUT}/checksums.sha256.txt";
const lines=fs.readFileSync(p,"utf8").trim().split("\n").filter(Boolean);
const obj={};
for(const line of lines){
  const [hash,file]=line.split(/\s+/);
  obj[file]=hash;
}
fs.writeFileSync("${OUT}/checksums.sha256.json", JSON.stringify({algo:"sha256",files:obj},null,2));
NODE
else
  echo "{}" > "${OUT}/checksums.sha256.json"
fi

echo
echo "✅ Release pack v3 (Phase28)
# Release pack ready:"
echo "  ${OUT}"
echo
echo "Files:"
ls -1 "$OUT" | sed 's/^/  - /'


# ============================================
# Release Pack v2 (Phase27)
# - includes smoke-phase27 + clear runbook
# ============================================

# ---- Phase31: Zapier Template Pack (best effort) ----
if [ -n "${TENANT_KEY:-}" ] && [ -n "${TENANT_ID:-}" ] && [ -n "${BASE_URL:-}" ]; then
  echo "==> Zapier Template Pack"
  BASE_URL="$BASE_URL" TENANT_ID="$TENANT_ID" TENANT_KEY="$TENANT_KEY" ./scripts/zapier-pack.sh || true
else
  echo "==> Zapier Template Pack (skipped: set BASE_URL + TENANT_ID + TENANT_KEY)"
fi
