#!/usr/bin/env bash
set -euo pipefail

say(){ echo "==> $*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -f "src/ui/routes.ts" ] || { echo "ERROR: missing src/ui/routes.ts"; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase30b_${TS}"
say "Phase30b OneShot (fix /ui/setup insertion robustly) @ $ROOT"
say "Backup -> $BAK"
mkdir -p "$BAK"
cp -R src/ui "$BAK/" 2>/dev/null || true
cp tsconfig.json "$BAK/" 2>/dev/null || true

say "Ensure tsconfig excludes backups"
node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
if (!fs.existsSync(p)) process.exit(0);
const j = JSON.parse(fs.readFileSync(p, "utf8"));
j.exclude = Array.isArray(j.exclude) ? j.exclude : [];
const need = ["__bak_*", "dist", "node_modules"];
for (const x of need) if (!j.exclude.includes(x)) j.exclude.push(x);
fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
console.log("✅ patched tsconfig.json exclude");
NODE

say "Patch src/ui/routes.ts (insert /ui/setup before /ui/tickets; no mountUi dependency)"
node - <<'NODE'
const fs = require("fs");
const p = "src/ui/routes.ts";
let s = fs.readFileSync(p, "utf8");

// Already patched?
if (s.includes('app.get("/ui/setup"') || s.includes("app.get('/ui/setup'")) {
  console.log("ℹ️ /ui/setup already exists; nothing to do.");
  process.exit(0);
}

// Find anchor route (tickets) to insert BEFORE it
const anchors = [
  'app.get("/ui/tickets"',
  "app.get('/ui/tickets'",
  'app.get("/ui/export.csv"',
  "app.get('/ui/export.csv'",
];
let idx = -1;
let anchorUsed = "";
for (const a of anchors) {
  idx = s.indexOf(a);
  if (idx !== -1) { anchorUsed = a; break; }
}
if (idx === -1) {
  throw new Error("Could not find anchor route (/ui/tickets or /ui/export.csv). Paste routes.ts header here and I’ll patch precisely.");
}

const block = `
  // -----------------------------
  // Client Setup (Zapier template)
  // -----------------------------
  app.get("/ui/setup", async (req: any, res: any) => {
    // expects requireUiAuth(req,res) to exist in this module (it does in your current UI)
    const auth = await (typeof requireUiAuth === "function" ? requireUiAuth(req, res) : null);
    if (!auth) return;

    const baseUrl =
      (req.protocol && req.get && req.get("host"))
        ? \`\${req.protocol}://\${req.get("host")}\`
        : (process.env.BASE_URL || "http://127.0.0.1:7090");

    const hookUrl = \`\${baseUrl}/api/webhook/intake?tenantId=\${encodeURIComponent(auth.tenantId)}&k=\${encodeURIComponent(auth.tenantKey)}\`;
    const ticketsUrl = \`\${baseUrl}/ui/tickets?tenantId=\${encodeURIComponent(auth.tenantId)}&k=\${encodeURIComponent(auth.tenantKey)}\`;
    const csvUrl = \`\${baseUrl}/ui/export.csv?tenantId=\${encodeURIComponent(auth.tenantId)}&k=\${encodeURIComponent(auth.tenantKey)}\`;
    const zipUrl = \`\${baseUrl}/ui/evidence.zip?tenantId=\${encodeURIComponent(auth.tenantId)}&k=\${encodeURIComponent(auth.tenantKey)}\`;

    const payload = {
      source: "zapier",
      lead: { name: "Jane Doe", email: "jane@example.com", phone: "+33 6 00 00 00 00" },
      message: "Interested in SEO + Ads audit. Budget 1500€/mo. Wants callback today.",
      utm: { campaign: "q1_agency_growth", adset: "retargeting", ad: "video_01" },
      meta: { externalId: "zap-" + new Date().toISOString(), raw: { note: "Map your trigger fields here" } }
    };

    const esc = (typeof escapeHtml === "function")
      ? escapeHtml
      : (x: any) => String(x).replace(/[&<>"]/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

    const render = (typeof renderPage === "function")
      ? renderPage
      : ((title: string, body: string) => \`<!doctype html><meta charset="utf-8"><title>\${esc(title)}</title><body>\${body}</body>\`);

    return res.status(200).send(render("Client Setup (Zapier)", \`
      <div class="card">
        <div class="h">Client Setup</div>
        <div class="muted">Connect Zapier (or any webhook) → tickets + dedupe + export.</div>

        <h3 style="margin:14px 0 6px">1) Webhook Endpoint</h3>
        <div class="muted">Zapier Action: Webhooks → Custom Request → POST</div>
        <pre>\${esc(hookUrl)}</pre>

        <h3 style="margin:14px 0 6px">2) JSON Payload (example)</h3>
        <div class="muted">Map trigger fields into this structure.</div>
        <pre>\${esc(JSON.stringify(payload, null, 2))}</pre>

        <h3 style="margin:14px 0 6px">3) Verify</h3>
        <div class="row">
          <a class="btn primary" href="\${ticketsUrl}">Open Tickets</a>
          <a class="btn" href="\${csvUrl}">Export CSV</a>
          <a class="btn" href="\${zipUrl}">Evidence ZIP</a>
        </div>

        <div class="muted" style="margin-top:10px">
          Tip: Give your client this page + webhook URL. Test in 60 seconds.
        </div>
      </div>
    \`));
  });

`;

s = s.slice(0, idx) + block + s.slice(idx);
fs.writeFileSync(p, s);
console.log(`✅ inserted /ui/setup before anchor: ${anchorUsed}`);
NODE

echo "==> Typecheck (best effort)"
if pnpm -s lint:types >/dev/null 2>&1; then
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase30b installed."
echo "Now restart:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then run:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase30.sh"
echo "And open /ui/setup from the printed link."
