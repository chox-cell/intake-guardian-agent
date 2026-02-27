#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase6f_${ts}"
mkdir -p "$bak"
cp -R src "$bak/src" 2>/dev/null || true
cp -R scripts "$bak/scripts" 2>/dev/null || true

echo "==> Phase6f OneShot (fix /ui/admin autolink via /api/admin/tenants/create) @ $ROOT"
echo "==> [0] Backup -> $bak"

mkdir -p src/ui scripts

echo "==> [1] Write src/ui/routes.ts (no tenants.create; use admin API + redirect 302)"
cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";

// Duck-typed stores (we do not assume exact interfaces)
type AnyStore = {
  listWorkItems?: (tenantId: string, q: any) => Promise<any[]>;
};
type AnyTenants = {
  verifyTenantKey?: (tenantId: string, key: string) => boolean;
};

// ---------- helpers
function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function getBaseUrl(req: Request) {
  const proto = (req.headers["x-forwarded-proto"] as string) || req.protocol || "http";
  const host = req.headers["x-forwarded-host"] || req.headers.host;
  return `${proto}://${host}`;
}

function getAdminKey(req: Request) {
  const h = (req.headers["x-admin-key"] as string) || "";
  const q = typeof req.query.ak === "string" ? req.query.ak : "";
  return h || q;
}

function mustAdmin(req: Request) {
  const ak = getAdminKey(req);
  if (!ak) {
    const err: any = new Error("admin_key_required");
    err.status = 401;
    throw err;
  }
  return ak;
}

function mustTenantKey(req: Request, tenantId: string, tenants: AnyTenants, store?: any) {
  const k =
    (req.headers["x-tenant-key"] as string) ||
    (typeof req.query.k === "string" ? req.query.k : "") ||
    "";

  const ok =
    (tenants && typeof tenants.verifyTenantKey === "function" && tenants.verifyTenantKey(tenantId, k)) ||
    (store && typeof store.verifyTenantKey === "function" && store.verifyTenantKey(tenantId, k));

  if (!ok) {
    const err: any = new Error("invalid_tenant_key");
    err.status = 401;
    throw err;
  }
  return k;
}

// ---------- UI pages
function renderClientPage(args: {
  tenantId: string;
  key: string;
  items: any[];
  baseUrl: string;
}) {
  const { tenantId, key, items, baseUrl } = args;

  const exportUrl = `${baseUrl}/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(key)}`;
  const ingestCurl = `curl -sS "${baseUrl}/api/adapters/email/sendgrid?tenantId=${tenantId}" \\
  -H "x-tenant-key: ${key}" \\
  -F 'from=employee@corp.local' \\
  -F 'subject=VPN broken (demo)' \\
  -F 'text=VPN is down ASAP.' | jq .`;

  const rows = (items || []).map((it: any) => {
    const id = esc(it.id);
    const subject = esc(it.subject || "");
    const sender = esc(it.sender || "");
    const status = esc(it.status || "");
    const priority = esc(it.priority || "");
    const createdAt = esc(it.createdAt || "");
    return `
      <tr>
        <td class="mono">${id}</td>
        <td>${subject}</td>
        <td>${sender}</td>
        <td><span class="pill">${status}</span></td>
        <td><span class="pill">${priority}</span></td>
        <td class="mono">${createdAt}</td>
      </tr>
    `;
  }).join("");

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Intake Guardian — Tickets</title>
  <style>
    :root { color-scheme: light; }
    body { font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial;
      margin: 0; background: #0b1220; color: #e8eefc; }
    .wrap { max-width: 1100px; margin: 0 auto; padding: 22px; }
    .card { background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.12);
      border-radius: 16px; padding: 16px; box-shadow: 0 12px 40px rgba(0,0,0,0.35); }
    h1 { margin: 0 0 8px; font-size: 20px; }
    .muted { color: rgba(232,238,252,0.72); font-size: 13px; }
    .row { display: flex; gap: 12px; flex-wrap: wrap; align-items: center; margin-top: 12px; }
    a.btn, button.btn { display: inline-flex; align-items: center; justify-content: center;
      gap: 8px; padding: 10px 12px; border-radius: 12px; text-decoration: none;
      border: 1px solid rgba(255,255,255,0.14); background: rgba(255,255,255,0.08);
      color: #e8eefc; font-weight: 600; font-size: 13px; cursor: pointer; }
    a.btn:hover, button.btn:hover { background: rgba(255,255,255,0.12); }
    table { width: 100%; border-collapse: collapse; margin-top: 14px; overflow: hidden; border-radius: 12px; }
    th, td { padding: 10px 10px; border-bottom: 1px solid rgba(255,255,255,0.10); font-size: 13px; }
    th { text-align: left; color: rgba(232,238,252,0.75); font-weight: 700; background: rgba(255,255,255,0.06); }
    .pill { padding: 4px 8px; border-radius: 999px; background: rgba(255,255,255,0.08);
      border: 1px solid rgba(255,255,255,0.12); font-size: 12px; }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 12px; }
    pre { background: rgba(0,0,0,0.35); border: 1px solid rgba(255,255,255,0.10);
      padding: 12px; border-radius: 12px; overflow: auto; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Tickets</h1>
      <div class="muted">Tenant: <span class="mono">${esc(tenantId)}</span></div>

      <div class="row">
        <a class="btn" href="${exportUrl}">⬇️ Export CSV</a>
        <a class="btn" href="https://wa.me/?text=${encodeURIComponent("Hello, I need help. My tenantId is "+tenantId)}" target="_blank" rel="noreferrer">💬 WhatsApp CTA</a>
        <a class="btn" href="${baseUrl}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(key)}">🔄 Refresh</a>
      </div>

      <div class="muted" style="margin-top:12px;">Demo ingest (copy/paste):</div>
      <pre class="mono">${esc(ingestCurl)}</pre>

      <table>
        <thead>
          <tr>
            <th>ID</th><th>Subject</th><th>Sender</th><th>Status</th><th>Priority</th><th>Created</th>
          </tr>
        </thead>
        <tbody>
          ${rows || `<tr><td colspan="6" class="muted">No tickets yet. Use the demo ingest above.</td></tr>`}
        </tbody>
      </table>
    </div>
  </div>
</body>
</html>`;
}

function toCsv(items: any[]) {
  const cols = ["id","subject","sender","status","priority","category","createdAt","dueAt"];
  const escCsv = (v: any) => {
    const s = String(v ?? "");
    if (s.includes('"') || s.includes(",") || s.includes("\n")) return `"${s.replaceAll('"','""')}"`;
    return s;
  };
  const head = cols.join(",");
  const body = (items || []).map((it:any) => cols.map((c) => escCsv(it?.[c])).join(",")).join("\n");
  return head + "\n" + body + "\n";
}

// ---------- mount
export function mountUi(app: Express, args: { store: AnyStore; tenants: AnyTenants }) {
  const store = args.store;
  const tenants = args.tenants;

  // Hide root UI
  app.get("/ui", (_req, res) => res.status(404).send("not_found"));

  // Admin autolink: create tenant via existing admin API, then redirect to client UI
  app.get("/ui/admin", async (req: Request, res: Response) => {
    try {
      const ak = mustAdmin(req);
      const baseUrl = getBaseUrl(req);

      const r = await fetch(`${baseUrl}/api/admin/tenants/create`, {
        method: "POST",
        headers: {
          "x-admin-key": ak,
          "content-type": "application/json",
        },
        body: "{}",
      });

      const txt = await r.text();
      if (!r.ok) {
        res.status(500).send(`<pre>admin_create_failed\nhttp=${r.status}\n${esc(txt)}</pre>`);
        return;
      }

      let data: any = null;
      try { data = JSON.parse(txt); } catch {}
      const tenantId = data?.tenantId;
      const tenantKey = data?.tenantKey;

      if (!tenantId || !tenantKey) {
        res.status(500).send(`<pre>missing_tenantId_or_key\n${esc(txt)}</pre>`);
        return;
      }

      const loc = `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;
      res.status(302).setHeader("Location", loc).end();
    } catch (e: any) {
      const status = Number(e?.status || 401);
      res.status(status).send(`<pre>${esc(e?.message || "admin_denied")}</pre>`);
    }
  });

  // Client tickets UI
  app.get("/ui/tickets", async (req: Request, res: Response) => {
    const tenantId = typeof req.query.tenantId === "string" ? req.query.tenantId : "";
    if (!tenantId) return res.status(400).send("<pre>missing_tenantId</pre>");

    try {
      const k = mustTenantKey(req, tenantId, tenants, store);
      const baseUrl = getBaseUrl(req);
      const items = (store.listWorkItems ? await store.listWorkItems(tenantId, {}) : []) || [];
      res.status(200).setHeader("content-type", "text/html; charset=utf-8").send(
        renderClientPage({ tenantId, key: k, items, baseUrl })
      );
    } catch (e: any) {
      res.status(Number(e?.status || 401)).send(`<pre>${esc(e?.message || "invalid_tenant_key")}</pre>`);
    }
  });

  // Export CSV
  app.get("/ui/export.csv", async (req: Request, res: Response) => {
    const tenantId = typeof req.query.tenantId === "string" ? req.query.tenantId : "";
    if (!tenantId) return res.status(400).send("missing_tenantId");

    try {
      mustTenantKey(req, tenantId, tenants, store);
      const items = (store.listWorkItems ? await store.listWorkItems(tenantId, {}) : []) || [];
      const csv = toCsv(items);
      res.status(200);
      res.setHeader("content-type", "text/csv; charset=utf-8");
      res.setHeader("content-disposition", `attachment; filename="tickets_${tenantId}.csv"`);
      res.send(csv);
    } catch (e: any) {
      res.status(Number(e?.status || 401)).send(e?.message || "invalid_tenant_key");
    }
  });
}
TS

echo "==> [2] Fix server.ts import (mountUi) if needed + ensure mount after store/tenants"
# minimal safe patch: replace mountUI->mountUi and remove early mount lines if exist
perl -0777 -i -pe '
  s/import\s*\{\s*mountUI\s*\}\s*from\s*["'\'']\.\/ui\/routes\.js["'\''];/import { mountUi } from ".\/ui\/routes.js";/g;
  s/\bmountUI\b/mountUi/g;
' src/server.ts

# remove early mountUi(app...) lines (if injected before declarations)
perl -i -ne 'next if $_ =~ /^\s*mountUi\s*\(\s*app.*\)\s*;\s*$/; print;' src/server.ts

# insert mountUi before app.listen if not present
node - <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

if (!s.includes('from "./ui/routes.js"') && !s.includes('from "./ui/routes"')) {
  // insert import near top
  s = s.replace(/(\nimport[^\n]*\n)+/, (m) => m + 'import { mountUi } from "./ui/routes.js";\n');
}

const listenIdx = s.search(/\bapp\.listen\s*\(/);
if (listenIdx === -1) {
  console.error("❌ app.listen not found in src/server.ts");
  process.exit(1);
}
if (!s.includes("mountUi(app")) {
  const inject = `\n  // UI (Phase6f) — mount after store+tenants exist\n  mountUi(app as any, { store: store as any, tenants: tenants as any });\n\n`;
  s = s.slice(0, listenIdx) + inject + s.slice(listenIdx);
}
fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mountUi injected before app.listen)");
NODE

echo "==> [3] Write scripts/demo-keys.sh (opens /ui/admin redirect)"
cat > scripts/demo-keys.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [[ -z "$ADMIN_KEY" ]]; then
  echo "missing_ADMIN_KEY"
  echo "use: ADMIN_KEY=super_secret_admin_123 BASE_URL=$BASE_URL ./scripts/demo-keys.sh"
  exit 1
fi

echo "==> Open /ui/admin (should 302 to client UI link)"
open "$BASE_URL/ui/admin?ak=$ADMIN_KEY" || true

echo
echo "==> Show redirect (Location header)"
curl -sS -I "$BASE_URL/ui/admin?ak=$ADMIN_KEY" | sed -n '1,25p'
SH2
chmod +x scripts/demo-keys.sh

echo "==> [4] Write scripts/smoke-ui.sh (expects 404, 302, export 200)"
cat > scripts/smoke-ui.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [[ -z "$ADMIN_KEY" ]]; then
  echo "missing_ADMIN_KEY"
  exit 1
fi

echo "==> [1] /ui hidden (404)"
s1="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/ui")"
echo "status=$s1"
[[ "$s1" == "404" ]] || { echo "FAIL: expected 404"; exit 1; }

echo "==> [2] /ui/admin redirect (302)"
s2="$(curl -sS -o /dev/null -w '%{http_code}' -I "$BASE_URL/ui/admin?ak=$ADMIN_KEY")"
echo "status=$s2"
[[ "$s2" == "302" ]] || { echo "FAIL: expected 302"; exit 1; }

loc="$(curl -sS -I "$BASE_URL/ui/admin?ak=$ADMIN_KEY" | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r\n')"
echo "location=$loc"

echo "==> [3] Fetch client page (200)"
s3="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL$loc")"
echo "status=$s3"
[[ "$s3" == "200" ]] || { echo "FAIL: expected 200"; exit 1; }

echo "==> [4] Export CSV (200)"
# derive export from same tenantId/k in loc
tenantId="$(python3 - <<PY 2>/dev/null || true
import urllib.parse,sys
u=sys.argv[1]
q=urllib.parse.parse_qs(urllib.parse.urlparse(u).query)
print(q.get("tenantId",[""])[0])
PY
"$loc")"
k="$(python3 - <<PY 2>/dev/null || true
import urllib.parse,sys
u=sys.argv[1]
q=urllib.parse.parse_qs(urllib.parse.urlparse(u).query)
print(q.get("k",[""])[0])
PY
"$loc")"

# fallback without python: simple regex
if [[ -z "${tenantId:-}" ]]; then tenantId="$(echo "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"; fi
if [[ -z "${k:-}" ]]; then k="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"; fi

exp="$BASE_URL/ui/export.csv?tenantId=$tenantId&k=$k"
s4="$(curl -sS -o /dev/null -w '%{http_code}' -I "$exp")"
echo "status=$s4"
[[ "$s4" == "200" ]] || { echo "FAIL: expected 200"; exit 1; }

echo "✅ smoke ok"
echo "client_ui: $BASE_URL$loc"
echo "export:    $exp"
SH2
chmod +x scripts/smoke-ui.sh

echo "==> [5] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase6f installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
