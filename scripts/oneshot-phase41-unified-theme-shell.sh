#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Phase41 OneShot (Unified Decision Cover™ Theme Shell for /ui/tickets + /ui/setup + /ui/decisions) @ $ROOT"
[ -d src ] || { echo "ERROR: run inside repo root (src missing)"; exit 1; }
[ -d scripts ] || { echo "ERROR: scripts missing"; exit 1; }

STAMP="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase41_${STAMP}"
mkdir -p "$BAK"
cp -R src scripts package.json tsconfig.json "$BAK" 2>/dev/null || true
echo "✅ backup -> $BAK"

mkdir -p src/ui

# -------------------------
# [1] Unified theme middleware (non-breaking: wraps existing HTML)
# -------------------------
cat > src/ui/unified_theme_mw.ts <<'TS'
import type { Express, Request, Response, NextFunction } from "express";

function esc(s: string) {
  return String(s || "").replace(/[&<>"']/g, (c) => {
    switch (c) {
      case "&": return "&amp;";
      case "<": return "&lt;";
      case ">": return "&gt;";
      case '"': return "&quot;";
      case "'": return "&#39;";
      default: return c;
    }
  });
}

function q(req: Request, key: string) {
  const v = (req.query as any)?.[key];
  if (Array.isArray(v)) return String(v[0] || "");
  return String(v || "");
}

function wantsWrap(req: Request) {
  const p = req.path || "";
  return p === "/ui/tickets" || p === "/ui/setup" || p === "/ui/decisions";
}

function tenantLinks(req: Request) {
  const tenantId = q(req, "tenantId");
  const k = q(req, "k");
  const qs = tenantId && k ? `?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}` : "";
  const base = (u: string) => `${u}${qs}`;

  return {
    tenantId, k,
    tickets: base("/ui/tickets"),
    decisions: base("/ui/decisions"),
    setup: base("/ui/setup"),
    csv: base("/ui/export.csv"),
    zip: base("/ui/evidence.zip"),
  };
}

function injectOnce(html: string) {
  // marker prevents double-wrapping
  return html.includes('data-dc-theme="1"');
}

function styleCss() {
  // keep inline, no external assets (print-safe + offline)
  return `
:root{
  --bg0:#07070a;
  --bg1:#0b0b12;
  --glass: rgba(255,255,255,.06);
  --glass2: rgba(255,255,255,.10);
  --line: rgba(255,255,255,.12);
  --txt: rgba(255,255,255,.92);
  --muted: rgba(255,255,255,.66);
  --muted2: rgba(255,255,255,.52);
  --brand: #7c5cff;
  --brand2:#00d4ff;
  --ok:#34d399;
  --warn:#fbbf24;
  --bad:#fb7185;
  --radius:16px;
  --shadow: 0 16px 40px rgba(0,0,0,.35);
  --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
  --sans: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, "Apple Color Emoji","Segoe UI Emoji";
}
*{box-sizing:border-box}
html,body{height:100%}
body{
  margin:0;
  font-family:var(--sans);
  color:var(--txt);
  background:
    radial-gradient(1200px 700px at 10% 10%, rgba(124,92,255,.22), transparent 55%),
    radial-gradient(900px 600px at 90% 20%, rgba(0,212,255,.18), transparent 55%),
    radial-gradient(1000px 800px at 50% 110%, rgba(255,255,255,.06), transparent 55%),
    linear-gradient(180deg, var(--bg0), var(--bg1));
}
a{color:inherit;text-decoration:none}
.dc-wrap{min-height:100%; padding:22px 16px 36px}
.dc-shell{max-width:1100px;margin:0 auto}
.dc-topbar{
  display:flex;align-items:center;justify-content:space-between;gap:12px;
  padding:14px 16px;border:1px solid var(--line);border-radius:var(--radius);
  background:linear-gradient(180deg, rgba(255,255,255,.08), rgba(255,255,255,.04));
  box-shadow:var(--shadow); backdrop-filter: blur(14px);
}
.dc-brand{display:flex;align-items:center;gap:10px}
.dc-logo{
  width:34px;height:34px;border-radius:12px;
  background: radial-gradient(circle at 30% 30%, rgba(255,255,255,.35), transparent 40%),
              linear-gradient(135deg, rgba(124,92,255,.95), rgba(0,212,255,.85));
  box-shadow:0 10px 22px rgba(124,92,255,.18);
}
.dc-title{font-weight:700;letter-spacing:.2px}
.dc-sub{font-size:12px;color:var(--muted)}
.dc-nav{display:flex;flex-wrap:wrap;gap:8px;align-items:center;justify-content:flex-end}
.dc-pill{
  border:1px solid var(--line);
  background:rgba(255,255,255,.05);
  padding:8px 10px;border-radius:999px;
  font-size:12px;color:var(--muted);
}
.dc-btn{
  border:1px solid rgba(124,92,255,.55);
  background:linear-gradient(135deg, rgba(124,92,255,.30), rgba(0,212,255,.16));
  padding:8px 12px;border-radius:999px;
  font-size:12px;font-weight:600;
}
.dc-btn:hover{filter:brightness(1.06)}
.dc-main{margin-top:14px}
.dc-card{
  border:1px solid var(--line);
  background:rgba(255,255,255,.05);
  border-radius:var(--radius);
  box-shadow:var(--shadow);
  backdrop-filter: blur(14px);
  padding:16px;
}
.dc-footer{
  margin-top:14px;
  display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;
  color:var(--muted2);font-size:12px;
}
.dc-k{font-family:var(--mono);font-size:12px;color:var(--muted)}
/* Make legacy tables nicer (tickets page) */
table{width:100%;border-collapse:collapse}
th,td{padding:10px 10px;border-bottom:1px solid rgba(255,255,255,.10);vertical-align:top}
th{color:rgba(255,255,255,.78);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.06em}
tr:hover td{background:rgba(255,255,255,.03)}
/* Legacy buttons/inputs */
input,select,textarea,button{font-family:inherit}
button,a.button,input[type="submit"]{
  cursor:pointer;
  border:1px solid rgba(255,255,255,.14);
  background:rgba(255,255,255,.06);
  color:var(--txt);
  padding:8px 12px;border-radius:12px;
}
button:hover,a.button:hover,input[type="submit"]:hover{background:rgba(255,255,255,.08)}
`;
}

function headerHtml(req: Request) {
  const L = tenantLinks(req);
  const hasTenant = Boolean(L.tenantId && L.k);

  const pill = hasTenant
    ? `<span class="dc-pill">tenantId: <span class="dc-k">${esc(L.tenantId)}</span></span>`
    : `<span class="dc-pill">Missing tenantId + k</span>`;

  const nav = hasTenant
    ? `
      <a class="dc-btn" href="${esc(L.decisions)}">Decisions</a>
      <a class="dc-btn" href="${esc(L.tickets)}">Tickets</a>
      <a class="dc-btn" href="${esc(L.setup)}">Setup</a>
      <a class="dc-btn" href="${esc(L.csv)}" target="_blank" rel="noreferrer">Export CSV</a>
      <a class="dc-btn" href="${esc(L.zip)}" target="_blank" rel="noreferrer">Evidence ZIP</a>
    `
    : `
      <a class="dc-btn" href="/ui/admin">Admin</a>
      <a class="dc-btn" href="/ui/setup">Setup</a>
    `;

  return `
<div class="dc-wrap" data-dc-theme="1">
  <div class="dc-shell">
    <div class="dc-topbar">
      <div class="dc-brand">
        <div class="dc-logo" aria-hidden="true"></div>
        <div>
          <div class="dc-title">Decision Cover™</div>
          <div class="dc-sub">If you must decide, decide with proof.</div>
        </div>
      </div>
      <div class="dc-nav">
        ${pill}
        ${nav}
      </div>
    </div>
    <div class="dc-main">
      <div class="dc-card">
`;
}

function footerHtml() {
  return `
      </div>
      <div class="dc-footer">
        <div>Decision Cover™ • Proof-first decisions • Vendor-neutral • No promises</div>
        <div>Integrity note: we avoid embedding secrets in UI. Tenant key is a link-token for demo client view.</div>
      </div>
    </div>
  </div>
</div>
`;
}

export function mountUnifiedTheme(app: Express) {
  app.use((req: Request, res: Response, next: NextFunction) => {
    if (!wantsWrap(req)) return next();

    const _send = res.send.bind(res);
    (res as any).send = (body: any) => {
      try {
        if (typeof body !== "string") return _send(body);
        const ct = String(res.getHeader("content-type") || "");
        const isHtml = ct.includes("text/html") || body.includes("<html") || body.includes("<!doctype") || body.includes("<body");
        if (!isHtml) return _send(body);
        if (injectOnce(body)) return _send(body);

        let html = body;

        // ensure head has our CSS
        if (html.includes("</head>")) {
          html = html.replace("</head>", `<style>${styleCss()}</style></head>`);
        } else {
          // if no head, prepend a minimal style anyway
          html = `<style>${styleCss()}</style>` + html;
        }

        // inject wrapper around body content (best effort)
        if (html.match(/<body[^>]*>/i) && html.match(/<\/body>/i)) {
          html = html.replace(/<body[^>]*>/i, (m) => `${m}${headerHtml(req)}`);
          html = html.replace(/<\/body>/i, () => `${footerHtml()}</body>`);
        } else {
          // fallback: wrap whole doc
          html = headerHtml(req) + html + footerHtml();
        }

        return _send(html);
      } catch {
        return _send(body);
      }
    };

    next();
  });
}
TS
echo "✅ wrote src/ui/unified_theme_mw.ts"

# -------------------------
# [2] Patch server.ts to mountUnifiedTheme(app) (additive)
# -------------------------
SERVER="src/server.ts"
[ -f "$SERVER" ] || { echo "ERROR: missing $SERVER"; exit 1; }
cp "$SERVER" "${SERVER}.bak.${STAMP}"

node <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

const importLine = 'import { mountUnifiedTheme } from "./ui/unified_theme_mw.js";';
if (!s.includes(importLine)) {
  const lines = s.split("\n");
  // place near other ui imports if present
  let idx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith("import ") && lines[i].includes('from "./ui/')) idx = i;
  }
  if (idx >= 0) lines.splice(idx + 1, 0, importLine);
  else {
    const firstImport = lines.findIndex((l) => l.startsWith("import "));
    lines.splice(Math.max(0, firstImport + 1), 0, importLine);
  }
  s = lines.join("\n");
}

// mount early (before UI routes), but it's safe even later
if (!s.includes("mountUnifiedTheme(app)")) {
  if (s.includes("const app = express()")) {
    s = s.replace("const app = express()", "const app = express()\n  mountUnifiedTheme(app)");
    s = s.replace("mountUnifiedTheme(app)\n", "mountUnifiedTheme(app);\n");
  } else if (s.includes("const app = express();")) {
    s = s.replace("const app = express();", "const app = express();\n  mountUnifiedTheme(app);\n");
  } else {
    // fallback: inject before first mountSetup/mountUi if found
    if (s.includes("mountSetup(app)")) {
      s = s.replace("mountSetup(app)", "mountUnifiedTheme(app);\n  mountSetup(app)");
    } else if (s.includes("mountUi(app)")) {
      s = s.replace("mountUi(app)", "mountUnifiedTheme(app);\n  mountUi(app)");
    } else {
      s += "\n\n// Unified UI theme\nmountUnifiedTheme(app);\n";
    }
  }
}

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mountUnifiedTheme)");
NODE

# -------------------------
# [3] Smoke Phase41
# -------------------------
cat > scripts/smoke-phase41.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:?missing ADMIN_KEY}"

fail(){ echo "FAIL: $*"; exit 1; }

echo "BASE_URL=$BASE_URL"
echo "==> health"
curl -sS "$BASE_URL/health" >/dev/null || fail "health failed"

echo "==> Location from /ui/admin"
hdr="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | tr -d '\r')"
loc="$(printf "%s\n" "$hdr" | awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="location"{print $2; exit}')"
[ -n "$loc" ] || { echo "---- debug headers ----"; echo "$hdr"; fail "no Location header"; }
echo "Location=$loc"

TENANT_ID="$(printf "%s" "$loc" | sed -n 's/.*[?&]tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(printf "%s" "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
[ -n "$TENANT_ID" ] || fail "tenantId parse failed"
[ -n "$TENANT_KEY" ] || fail "k parse failed"

TICKETS="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
SETUP="$BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY"
DECISIONS="$BASE_URL/ui/decisions?tenantId=$TENANT_ID&k=$TENANT_KEY"

echo "==> tickets 200 + themed"
curl -s -o /dev/null -w "%{http_code}" "$TICKETS" | grep -q 200 || fail "tickets not 200"
curl -s "$TICKETS" | grep -q 'data-dc-theme="1"' || fail "tickets not themed"

echo "==> setup 200 + themed"
curl -s -o /dev/null -w "%{http_code}" "$SETUP" | grep -q 200 || fail "setup not 200"
curl -s "$SETUP" | grep -q 'data-dc-theme="1"' || fail "setup not themed"

echo "==> decisions 200 + themed"
curl -s -o /dev/null -w "%{http_code}" "$DECISIONS" | grep -q 200 || fail "decisions not 200"
curl -s "$DECISIONS" | grep -q 'data-dc-theme="1"' || fail "decisions not themed"

echo
echo "✅ Phase41 smoke OK"
echo "Tickets:"
echo "  $TICKETS"
echo "Setup:"
echo "  $SETUP"
echo "Decisions:"
echo "  $DECISIONS"
