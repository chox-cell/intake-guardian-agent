#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_ui_root_${TS}"

echo "==> [0] Backup -> ${BAK}"
mkdir -p "${BAK}/src"
cp -a "src/server.ts" "${BAK}/src/server.ts" 2>/dev/null || true

echo "==> [1] Ensure src/ui"
mkdir -p src/ui

echo "==> [2] Write src/ui/routes.ts (adds /ui root route)"
cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function renderUiHome(baseUrl: string) {
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>Intake-Guardian — UI</title>
  <style>
    :root{
      --bg:#070b12;--card:#0c1220;--muted:#9aa4b2;--text:#e6edf3;
      --line:rgba(255,255,255,.08);--btn:#1f6feb;--btn2:#238636;
    }
    *{box-sizing:border-box}
    body{
      margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial;
      background: radial-gradient(1200px 600px at 20% 0%, #111a33 0%, var(--bg) 60%);
      color:var(--text);
    }
    .wrap{max-width:980px;margin:0 auto;padding:28px}
    .card{
      background: linear-gradient(180deg, rgba(255,255,255,.06), rgba(255,255,255,.03));
      border:1px solid var(--line);
      border-radius:18px;
      padding:18px;
      box-shadow: 0 12px 32px rgba(0,0,0,.35);
    }
    h1{margin:0 0 6px;font-size:22px;letter-spacing:.2px}
    p{margin:0 0 14px;color:var(--muted);font-size:13px;line-height:1.45}
    .row{display:flex;gap:10px;flex-wrap:wrap}
    .field{
      flex:1; min-width:240px;
      background: rgba(0,0,0,.2);
      border:1px solid var(--line);
      border-radius:14px;
      padding:10px 12px;
      color:var(--text);
      outline:none;
    }
    .btn{
      border:1px solid var(--line);
      border-radius:14px;
      padding:10px 14px;
      cursor:pointer;
      font-weight:700;
      color:var(--text);
      background: rgba(255,255,255,.06);
    }
    .btn.primary{background: rgba(31,111,235,.25); border-color: rgba(31,111,235,.45)}
    .btn.green{background: rgba(35,134,54,.25); border-color: rgba(35,134,54,.45)}
    .mini{margin-top:10px;color:var(--muted);font-size:12px}
    code{
      display:block;margin-top:12px;
      background: rgba(0,0,0,.35);
      border:1px solid var(--line);
      border-radius:14px;
      padding:12px;
      color:#d1e7ff;
      overflow:auto;
      font-size:12px;
      white-space:pre;
    }
    a{color:#8ab4ff;text-decoration:none}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Intake-Guardian UI</h1>
      <p>Open Tickets UI. If you already have a tenant link, paste it here. Otherwise run the demo keys script once.</p>

      <div class="row" style="margin:10px 0 12px">
        <input id="tenantId" class="field" placeholder="tenantId (e.g. tenant_...)" />
        <input id="k" class="field" placeholder="key (k=...)" />
        <button class="btn primary" onclick="go()">Open Tickets</button>
        <button class="btn green" onclick="exp()">Export CSV</button>
      </div>

      <div class="mini">
        Tip: if you generated a link like <b>/ui/tickets?tenantId=...&k=...</b> just paste tenantId + k above.
      </div>

      <code id="help">Demo keys (one command):
BASE_URL=${esc(baseUrl)} ./scripts/demo-keys.sh</code>
    </div>
  </div>

<script>
const BASE = ${JSON.stringify(baseUrl)};
function go(){
  const t = document.getElementById("tenantId").value.trim();
  const k = document.getElementById("k").value.trim();
  if(!t || !k){ alert("Paste tenantId + key first (or run demo-keys.sh)"); return; }
  window.location.href = BASE + "/ui/tickets?tenantId=" + encodeURIComponent(t) + "&k=" + encodeURIComponent(k);
}
function exp(){
  const t = document.getElementById("tenantId").value.trim();
  const k = document.getElementById("k").value.trim();
  if(!t || !k){ alert("Paste tenantId + key first (or run demo-keys.sh)"); return; }
  window.location.href = BASE + "/ui/export.csv?tenantId=" + encodeURIComponent(t) + "&k=" + encodeURIComponent(k);
}
</script>
</body>
</html>`;
}

export function mountUI(app: Express) {
  // base = same host (works local + forwarded)
  app.get("/ui", (req: Request, res: Response) => {
    // If user already has tenantId/k in query, bounce to tickets
    const tenantId = String(req.query.tenantId ?? "").trim();
    const k = String(req.query.k ?? "").trim();
    const baseUrl = `${req.protocol}://${req.get("host")}`;

    if (tenantId && k) {
      return res.redirect(302, `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`);
    }
    return res.status(200).send(renderUiHome(baseUrl));
  });

  // optional: quick sanity
  app.get("/ui/health", (_req: Request, res: Response) => {
    res.json({ ok: true });
  });
}
TS

echo "==> [3] Patch src/server.ts (import + mountUI(app))"
SERVER="src/server.ts"
if [ ! -f "$SERVER" ]; then
  echo "❌ missing src/server.ts"
  exit 1
fi

# add import if missing
if ! grep -q 'mountUI' "$SERVER"; then
  # Insert after first import block (best-effort)
  # We add near top: after line containing express import OR after first line
  if grep -q 'from "express"' "$SERVER"; then
    perl -0777 -i -pe 's/(from "express";\n)/$1import { mountUI } from ".\/ui\/routes.js";\n/s' "$SERVER"
  else
    perl -0777 -i -pe 's/^/import { mountUI } from ".\/ui\/routes.js";\n/s' "$SERVER"
  fi
fi

# mount after app creation
if ! grep -q 'mountUI\(app\)' "$SERVER"; then
  # common pattern: const app = express();
  if grep -q 'const app = express' "$SERVER"; then
    perl -0777 -i -pe 's/(const app = express\(\);\n)/$1\n\/\/ UI root\nmountUI(app);\n\n/s' "$SERVER"
  elif grep -q 'let app = express' "$SERVER"; then
    perl -0777 -i -pe 's/(let app = express\(\);\n)/$1\n\/\/ UI root\nmountUI(app);\n\n/s' "$SERVER"
  else
    echo "❌ Could not find app creation line (const app = express()). Open src/server.ts and add: mountUI(app) after app creation."
    exit 1
  fi
fi

echo "==> [4] Typecheck"
pnpm -s lint:types

echo
echo "✅ Done. Restart server:"
echo "  pnpm dev"
echo
echo "Open:"
echo "  http://127.0.0.1:7090/ui"
echo "  http://127.0.0.1:7090/ui/health"
