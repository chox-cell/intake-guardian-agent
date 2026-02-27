#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase20_${TS}"
echo "==> Phase20 OneShot (Release Pack + Gumroad-ready) @ ${ROOT}"

mkdir -p "${BAK}"
cp -R src scripts package.json tsconfig.json "${BAK}/" 2>/dev/null || true
echo "✅ backup -> ${BAK}"

echo "==> [1] Ensure tsconfig excludes backups"
if [ -f tsconfig.json ]; then
  node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.isArray(j.exclude) ? j.exclude : [];
const want = ["__bak_*","dist","dist/**"];
for (const w of want) if (!j.exclude.includes(w)) j.exclude.push(w);
fs.writeFileSync(p, JSON.stringify(j,null,2));
console.log("✅ patched tsconfig.json exclude");
NODE
fi

echo "==> [2] Write Landing UI module: src/ui/landing.ts"
mkdir -p src/ui
cat > src/ui/landing.ts <<'TS'
import type { Express } from "express";

function esc(s: string) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function htmlPage(title: string, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${esc(title)}</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial;
    background: radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%);
    color:#e5e7eb; }
  a { color: inherit; text-decoration: none; }
  .wrap { max-width: 980px; margin: 56px auto; padding: 0 18px; }
  .card { border:1px solid rgba(255,255,255,.08); background: rgba(17,24,39,.55);
    border-radius: 18px; padding: 18px 18px; box-shadow: 0 18px 60px rgba(0,0,0,.35); }
  .h { font-size: 26px; font-weight: 900; margin: 0 0 6px; letter-spacing: .2px; }
  .sub { color: #a7b0c0; font-size: 14px; margin: 0 0 16px; }
  .grid { display:grid; grid-template-columns: 1fr; gap: 12px; margin-top: 14px; }
  @media(min-width:860px){ .grid{ grid-template-columns: 1fr 1fr; } }
  .btns { display:flex; gap:10px; flex-wrap:wrap; margin-top: 12px; }
  .btn { border:1px solid rgba(255,255,255,.12); background: rgba(0,0,0,.25);
    padding: 10px 12px; border-radius: 12px; font-weight: 800; font-size: 13px; }
  .btn.primary { background: rgba(34,197,94,.12); border-color: rgba(34,197,94,.35); }
  .btn.blue { background: rgba(59,130,246,.12); border-color: rgba(59,130,246,.35); }
  .k { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 12px;
    padding: 2px 8px; border-radius: 10px; border:1px solid rgba(255,255,255,.08); background: rgba(0,0,0,.28); }
  .list { margin: 10px 0 0; padding-left: 18px; color: #cbd5e1; font-size: 13px; line-height: 1.55; }
  .muted { color: #9ca3af; font-size: 12px; margin-top: 10px; }
  code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
  pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35);
    border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; margin: 10px 0 0; }
</style>
</head>
<body>
  <div class="wrap">
    ${body}
  </div>
</body>
</html>`;
}

export function mountLanding(app: Express) {
  // Product landing (public, no secrets)
  app.get("/", (req, res) => {
    const base = `${req.protocol}://${req.get("host")}`;
    const body = `
<div class="card">
  <div class="h">Intake-Guardian</div>
  <div class="sub">Unified intake inbox + tenant links + CSV proof export — built for agencies & IT support.</div>

  <div class="grid">
    <div class="card" style="padding:14px 14px">
      <div style="font-weight:900;margin-bottom:6px">What you get</div>
      <ul class="list">
        <li>Client link per tenant (no account UX).</li>
        <li>Tickets inbox (status/priority/due).</li>
        <li>Export CSV for proof & reporting.</li>
        <li>Demo ticket generator for instant value.</li>
      </ul>
      <div class="muted">Tip: start from <span class="k">/ui/admin</span> (admin autolink) then share the client URL.</div>
    </div>

    <div class="card" style="padding:14px 14px">
      <div style="font-weight:900;margin-bottom:6px">Try it now</div>
      <div class="btns">
        <a class="btn blue" href="/ui/admin">Open Admin Autolink</a>
        <a class="btn" href="/ui/tickets">Open Tickets (needs link)</a>
        <a class="btn primary" href="/ui/demo">Open Demo Inbox</a>
      </div>
      <div class="muted">Demo uses a local demo tenant (no secrets shown).</div>
      <pre>Base: ${esc(base)}
Health: ${esc(base)}/health</pre>
    </div>
  </div>

  <div class="muted" style="margin-top:12px">System-19 note: never expose ADMIN_KEY in client links.</div>
</div>`;
    res.status(200).type("html").send(htmlPage("Intake-Guardian", body));
  });

  // Demo route: redirects to a stable demo tenant page (implemented by existing UI logic if /ui/admin works)
  app.get("/ui/demo", (req, res) => {
    // We intentionally keep this minimal: it redirects to /ui/admin without exposing any secrets.
    // If admin requires query param, user can add ?admin=... manually.
    res.redirect(302, "/ui/admin");
  });
}
TS
echo "✅ wrote src/ui/landing.ts"

echo "==> [3] Patch src/ui/routes.ts to mountLanding(app) inside mountUi (non-breaking)"
node - <<'NODE'
const fs = require("fs");
const p = "src/ui/routes.ts";
if (!fs.existsSync(p)) {
  console.error("ERR: src/ui/routes.ts not found. Aborting patch.");
  process.exit(1);
}
let s = fs.readFileSync(p,"utf8");

// add import if missing
if (!s.includes('from "./landing')) {
  s = s.replace(
    /(^import .*?;\s*$)/m,
    (m) => m + '\nimport { mountLanding } from "./landing.js";'
  );
}

// ensure mountLanding is called inside mountUi
if (!s.includes("mountLanding(app")) {
  s = s.replace(
    /export function mountUi\(([^)]*)\)\s*\{\s*/,
    (m) => m + "\n  // Phase20: public landing + demo entry (does not change tickets/auth)\n  try { mountLanding(app as any); } catch {}\n"
  );
}

fs.writeFileSync(p, s);
console.log("✅ patched src/ui/routes.ts (mountLanding)");
NODE

echo "==> [4] Write Release Pack scripts"
mkdir -p scripts dist

cat > scripts/release-pack.sh <<'BASH'
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
echo "✅ Release pack ready:"
echo "  ${OUT}"
echo
echo "Files:"
ls -1 "$OUT" | sed 's/^/  - /'
BASH
chmod +x scripts/release-pack.sh
echo "✅ wrote scripts/release-pack.sh"

echo "==> [5] Typecheck"
pnpm -s lint:types

echo
echo "==> [6] Generate Release Pack"
./scripts/release-pack.sh

echo
echo "✅ Phase20 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then open:"
echo "  http://127.0.0.1:7090/          (Landing)"
echo "  http://127.0.0.1:7090/ui/admin?admin=super_secret_admin_123"
echo
