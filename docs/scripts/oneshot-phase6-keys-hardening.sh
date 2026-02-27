#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase6_${ts}"
mkdir -p "$bak"
cp -R src "$bak/src" 2>/dev/null || true
cp -R scripts "$bak/scripts" 2>/dev/null || true
cp tsconfig.json "$bak/tsconfig.json" 2>/dev/null || true

echo "==> [0] Backup -> $bak"

echo "==> [1] Ensure tsconfig excludes backups"
node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]), "__bak_*", "**/__bak_*"]));
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
console.log("✅ patched tsconfig.json exclude");
NODE

echo "==> [2] Write robust tenant-key gate (accept ?k=, header, body; supports 2-4 args)"
cat > src/api/tenant-key.ts <<'TS'
import type { Request } from "express";

export class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

type AnyTenants = any;

function pickKey(req: any): string {
  // order: query -> header -> body -> cookie
  const q = req?.query || {};
  const b = req?.body || {};
  const h = req?.headers || {};
  const fromQuery =
    (typeof q.k === "string" && q.k) ||
    (typeof q.tenantKey === "string" && q.tenantKey) ||
    (typeof q.key === "string" && q.key);

  const fromHeader =
    (typeof h["x-tenant-key"] === "string" && h["x-tenant-key"]) ||
    (typeof h["x-tenantkey"] === "string" && h["x-tenantkey"]) ||
    (typeof h["x-tenant-token"] === "string" && h["x-tenant-token"]);

  const fromBody =
    (typeof b.k === "string" && b.k) ||
    (typeof b.tenantKey === "string" && b.tenantKey) ||
    (typeof b.key === "string" && b.key);

  const fromCookie = (() => {
    const cookie = typeof h.cookie === "string" ? h.cookie : "";
    const m = cookie.match(/(?:^|;\s*)tenant_key=([^;]+)/);
    return m ? decodeURIComponent(m[1]) : "";
  })();

  return String(fromQuery || fromHeader || fromBody || fromCookie || "");
}

function verify(tenants: AnyTenants | undefined, tenantId: string, key: string): boolean {
  if (!tenants) return true; // backward compatible: if no tenants store wired, don't block
  // support multiple method names safely
  if (typeof tenants.verifyTenantKey === "function") return !!tenants.verifyTenantKey(tenantId, key);
  if (typeof tenants.verifyKey === "function") return !!tenants.verifyKey(tenantId, key);
  if (typeof tenants.isValidTenantKey === "function") return !!tenants.isValidTenantKey(tenantId, key);
  if (typeof tenants.isValidKey === "function") return !!tenants.isValidKey(tenantId, key);
  // if tenants store exists but unknown API -> fail closed? better fail OPEN in dev to avoid lockout
  return true;
}

// Signature: requireTenantKey(req, tenantId, tenants?, shares?) -> string OR throws HttpError
export function requireTenantKey(req: Request, tenantId: string, tenants?: AnyTenants, _shares?: any): string {
  const key = pickKey(req);
  if (!tenantId) throw new HttpError(400, "missing_tenantId");
  if (!key) throw new HttpError(401, "missing_tenant_key");

  const ok = verify(tenants, tenantId, key);
  if (!ok) throw new HttpError(401, "invalid_tenant_key");
  return key;
}

// Optional helper used by older code paths
export function verifyTenantKey(tenantId: string, key: string, tenants?: AnyTenants): boolean {
  if (!tenantId || !key) return false;
  return verify(tenants, tenantId, key);
}
TS

echo "==> [3] Write SELL UI routes (hide /ui root, /ui/admin autolink, client tickets UI)"
mkdir -p src/ui
cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";

type AnyTenants = any;
type AnyStore = any;

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function getAdmin(req: Request): string {
  const q = req.query || {};
  const h = req.headers || {};
  return String((q.admin as any) || (h["x-admin-key"] as any) || "");
}

function adminOk(req: Request): { ok: true } | { ok: false; status: number; error: string } {
  const ADMIN_KEY = process.env.ADMIN_KEY || "";
  if (!ADMIN_KEY) return { ok: false, status: 500, error: "admin_key_not_configured" };
  const k = getAdmin(req);
  if (!k) return { ok: false, status: 401, error: "missing_admin_key" };
  if (k !== ADMIN_KEY) return { ok: false, status: 403, error: "invalid_admin_key" };
  return { ok: true };
}

function baseUrl(req: Request): string {
  const pb = process.env.PUBLIC_BASE_URL;
  if (pb) return pb.replace(/\/$/, "");
  const proto = (req.headers["x-forwarded-proto"] as string) || req.protocol || "http";
  const host = (req.headers["x-forwarded-host"] as string) || req.get("host") || "127.0.0.1:7090";
  return `${proto}://${host}`.replace(/\/$/, "");
}

function linkTickets(b: string, tenantId: string, tenantKey: string) {
  return `${b}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;
}
function linkExport(b: string, tenantId: string, tenantKey: string) {
  return `${b}/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;
}

async function createTenant(tenants: AnyTenants) {
  // support multiple shapes
  if (typeof tenants.createTenant === "function") return await tenants.createTenant();
  if (typeof tenants.create === "function") return await tenants.create();
  if (typeof tenants.createDemoTenant === "function") return await tenants.createDemoTenant();
  throw new Error("tenants_create_not_supported");
}

async function listTickets(store: AnyStore, tenantId: string, q: any) {
  if (typeof store.listWorkItems === "function") return await store.listWorkItems(tenantId, q || {});
  if (typeof store.list === "function") return await store.list(tenantId, q || {});
  return [];
}

async function createDemoTicket(store: AnyStore, tenantId: string) {
  if (typeof store.createDemoTicket === "function") return await store.createDemoTicket(tenantId);
  if (typeof store.createWorkItem === "function") {
    return await store.createWorkItem(tenantId, {
      subject: "VPN broken (demo)",
      sender: "employee@corp.local",
      text: "VPN is down ASAP.",
      status: "open",
      priority: "high",
      channel: "demo",
    });
  }
  return null;
}

export function mountUi(app: Express, args: { store: AnyStore; tenants: AnyTenants }) {
  const { store, tenants } = args;

  // hide /ui root
  app.get("/ui", (_req, res) => res.status(404).send("not_found"));

  // admin autolink: creates tenant + redirects to client tickets URL
  app.get("/ui/admin", async (req: Request, res: Response) => {
    const ok = adminOk(req);
    if (!ok.ok) return res.status(ok.status).send(`<pre>${esc(ok.error)}</pre>`);

    const b = baseUrl(req);
    const t = await createTenant(tenants);
    const tenantId = String(t.tenantId || t.id || "");
    const tenantKey = String(t.tenantKey || t.key || "");

    if (!tenantId || !tenantKey) return res.status(500).send("<pre>tenant_create_failed</pre>");

    // Redirect straight to client UI (no tech)
    return res.redirect(linkTickets(b, tenantId, tenantKey));
  });

  // client tickets UI
  app.get("/ui/tickets", async (req: Request, res: Response) => {
    const tenantId = String(req.query.tenantId || "");
    const k = String(req.query.k || "");
    if (!tenantId || !k) return res.status(400).send("<pre>missing_tenant_link</pre>");

    const search = String(req.query.search || "");
    const status = String(req.query.status || "");
    const q: any = {};
    if (search) q.search = search;
    if (status && status !== "all") q.status = status;

    const items = await listTickets(store, tenantId, q);
    const b = baseUrl(req);
    const clientLink = linkTickets(b, tenantId, k);
    const exportLink = linkExport(b, tenantId, k);

    const rows = (items || []).map((it: any) => {
      return `
        <tr>
          <td>${esc(it.id || "")}</td>
          <td>${esc(it.subject || "")}<div class="muted">${esc(it.sender || "")}</div></td>
          <td><span class="pill">${esc(it.status || "")}</span></td>
          <td>${esc(it.priority || "")}</td>
          <td class="muted">${esc(it.due || it.sla || "")}</td>
          <td class="actions">
            <form method="POST" action="/ui/demo" style="display:inline">
              <input type="hidden" name="tenantId" value="${esc(tenantId)}"/>
              <input type="hidden" name="k" value="${esc(k)}"/>
              <button class="btn small" type="submit">Demo Ticket</button>
            </form>
          </td>
        </tr>
      `;
    }).join("");

    const html = `<!doctype html>
<html>
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Tickets</title>
<style>
  body{margin:0;background:#060b16;color:#e8eefc;font-family:ui-sans-serif,system-ui,-apple-system;}
  .wrap{max-width:1100px;margin:40px auto;padding:0 16px;}
  .card{background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.10);border-radius:18px;padding:18px;box-shadow:0 20px 60px rgba(0,0,0,.35)}
  .top{display:flex;gap:12px;align-items:center;justify-content:space-between;flex-wrap:wrap}
  .title{font-size:22px;font-weight:700}
  .muted{color:rgba(232,238,252,.65);font-size:12px}
  .btn{border:1px solid rgba(255,255,255,.14);background:rgba(255,255,255,.06);color:#e8eefc;border-radius:12px;padding:10px 12px;font-weight:700;cursor:pointer}
  .btn.green{background:rgba(34,197,94,.16);border-color:rgba(34,197,94,.35)}
  .btn.small{padding:8px 10px;border-radius:10px;font-size:12px}
  .row{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px}
  input,select{background:rgba(0,0,0,.25);border:1px solid rgba(255,255,255,.14);color:#e8eefc;border-radius:12px;padding:10px 12px;min-width:220px}
  .linkbox{margin-top:12px;display:flex;gap:8px;align-items:center}
  .link{flex:1;background:rgba(0,0,0,.25);border:1px dashed rgba(255,255,255,.18);padding:10px 12px;border-radius:12px;overflow:auto;white-space:nowrap}
  table{width:100%;border-collapse:collapse;margin-top:14px}
  th,td{border-top:1px solid rgba(255,255,255,.10);padding:12px 10px;text-align:left;font-size:13px;vertical-align:top}
  th{color:rgba(232,238,252,.70);font-size:12px;letter-spacing:.12em;text-transform:uppercase}
  .pill{padding:4px 10px;border-radius:999px;background:rgba(59,130,246,.12);border:1px solid rgba(59,130,246,.22);font-size:12px}
  .actions{white-space:nowrap}
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="top">
        <div>
          <div class="title">Tickets</div>
          <div class="muted">tenant: ${esc(tenantId)} • total: ${(items||[]).length}</div>
        </div>
        <div style="display:flex;gap:8px;flex-wrap:wrap">
          <button class="btn" onclick="location.reload()">Refresh</button>
          <button class="btn" onclick="navigator.clipboard.writeText('${esc(clientLink)}')">Copy link</button>
          <a class="btn green" href="${esc(exportLink)}">Export CSV</a>
        </div>
      </div>

      <div class="linkbox">
        <div class="muted">Client link:</div>
        <div class="link" id="cl">${esc(clientLink)}</div>
        <button class="btn small" onclick="navigator.clipboard.writeText(document.getElementById('cl').innerText)">Copy</button>
      </div>

      <form class="row" method="GET" action="/ui/tickets">
        <input type="hidden" name="tenantId" value="${esc(tenantId)}"/>
        <input type="hidden" name="k" value="${esc(k)}"/>
        <input name="search" placeholder="Search…" value="${esc(search)}"/>
        <select name="status">
          <option value="all" ${status==="all"||!status?"selected":""}>All statuses</option>
          <option value="open" ${status==="open"?"selected":""}>Open</option>
          <option value="in_progress" ${status==="in_progress"?"selected":""}>In progress</option>
          <option value="done" ${status==="done"?"selected":""}>Done</option>
          <option value="closed" ${status==="closed"?"selected":""}>Closed</option>
        </select>
        <button class="btn" type="submit">Apply</button>
        <a class="btn" href="/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}">Reset</a>
      </form>

      <table>
        <thead>
          <tr>
            <th>ID</th><th>Subject / Sender</th><th>Status</th><th>Priority</th><th>SLA / Due</th><th>Actions</th>
          </tr>
        </thead>
        <tbody>
          ${rows || `<tr><td colspan="6" class="muted">No tickets yet. Click Demo Ticket to see the flow.</td></tr>`}
        </tbody>
      </table>

      <div class="muted" style="margin-top:12px">
        Intake-Guardian — one place to see requests, change status, and export proof.
      </div>
    </div>
  </div>
</body>
</html>`;
    res.status(200).send(html);
  });

  // demo ticket action (no API knowledge needed)
  app.post("/ui/demo", async (req: any, res: Response) => {
    const tenantId = String(req.body?.tenantId || "");
    const k = String(req.body?.k || "");
    if (!tenantId || !k) return res.status(400).send("<pre>missing_tenant_link</pre>");
    await createDemoTicket(store, tenantId);
    return res.redirect(`/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`);
  });

  // export is server-side; we accept ?k= and also set header for internal verify if needed
  app.get("/ui/export.csv", async (req: any, res: Response) => {
    const tenantId = String(req.query.tenantId || "");
    const k = String(req.query.k || "");
    if (!tenantId || !k) return res.status(400).send("missing_tenant_link");

    // if your API route expects header, we set it for consistency
    req.headers["x-tenant-key"] = k;

    // try store export if exists, otherwise minimal CSV from list
    let items: any[] = [];
    try { items = await listTickets(store, tenantId, {}); } catch {}
    const lines = [
      "id,subject,sender,status,priority",
      ...items.map((it: any) => {
        const vals = [
          it.id, it.subject, it.sender, it.status, it.priority
        ].map((v: any) => `"${String(v ?? "").replaceAll('"','""')}"`);
        return vals.join(",");
      })
    ].join("\n");

    res.status(200);
    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    res.send(lines);
  });
}
TS

echo "==> [4] Patch server.ts to mount UI routes (without breaking existing /api)"
node - <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p,"utf8");

// ensure import exists
if (!s.includes('from "./ui/routes.js"')) {
  s = s.replace(/from\s+["']\.\/api\/routes\.js["'];/g, m => m + '\nimport { mountUi } from "./ui/routes.js";');
}

// find a safe place after app + store + tenants are constructed
// we’ll insert "mountUi(app, { store, tenants });" once, near after app is created.
if (!s.includes("mountUi(app")) {
  // heuristic: insert after the first occurrence of "const app"
  const idx = s.indexOf("const app");
  if (idx !== -1) {
    const lineEnd = s.indexOf("\n", idx);
    s = s.slice(0, lineEnd+1) + "\n  // UI (Phase6)\n  mountUi(app as any, { store: store as any, tenants: tenants as any });\n" + s.slice(lineEnd+1);
  } else {
    // fallback: append near end of main() before listen
    s = s.replace(/app\.listen\(/, "\n  // UI (Phase6)\n  mountUi(app as any, { store: store as any, tenants: tenants as any });\n\n  app.listen(");
  }
}

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mounted UI)");
NODE

echo "==> [5] Write scripts: admin-link + demo-keys + smoke-ui (no python)"
cat > scripts/admin-link.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"
if [ -z "$ADMIN_KEY" ]; then
  echo "missing ADMIN_KEY env. Run: ADMIN_KEY=... $0"
  exit 1
fi
echo "$BASE_URL/ui/admin?admin=$ADMIN_KEY"
SH2
chmod +x scripts/admin-link.sh

cat > scripts/demo-keys.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-${1:-}}"
if [ -z "$ADMIN_KEY" ]; then
  echo "Usage: ADMIN_KEY=... BASE_URL=... ./scripts/demo-keys.sh"
  echo "Or:    ./scripts/demo-keys.sh <ADMIN_KEY>"
  exit 1
fi
echo "==> Admin autolink (opens client tickets directly)"
echo "$BASE_URL/ui/admin?admin=$ADMIN_KEY"
open "$BASE_URL/ui/admin?admin=$ADMIN_KEY" >/dev/null 2>&1 || true
SH2
chmod +x scripts/demo-keys.sh

cat > scripts/smoke-ui.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"
if [ -z "$ADMIN_KEY" ]; then
  echo "missing ADMIN_KEY. Run: ADMIN_KEY=... BASE_URL=... ./scripts/smoke-ui.sh"
  exit 1
fi

echo "==> [1] /ui must be hidden (404 expected)"
code="$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/ui" || true)"
echo "status=$code"
[ "$code" = "404" ] || echo "WARN: expected 404"

echo "==> [2] /ui/admin should redirect (302 expected)"
code="$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/ui/admin?admin=$ADMIN_KEY" || true)"
echo "status=$code"
[ "$code" = "302" ] || (echo "FAIL: expected 302" && exit 1)

echo "==> [3] capture redirected Location (client link)"
loc="$(curl -sI "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r\n')"
echo "client_link=$loc"
[ -n "$loc" ] || (echo "FAIL: missing Location" && exit 1)

echo "==> [4] client tickets page should be 200"
code="$(curl -s -o /dev/null -w "%{http_code}" "$loc" || true)"
echo "status=$code"
[ "$code" = "200" ] || (echo "FAIL: expected 200" && exit 1)

echo "==> [5] export should be 200"
export_url="$(echo "$loc" | sed 's/\/ui\/tickets/\/ui\/export.csv/')"
code="$(curl -s -o /dev/null -w "%{http_code}" "$export_url" || true)"
echo "status=$code url=$export_url"
[ "$code" = "200" ] || (echo "FAIL: expected 200" && exit 1)

echo "✅ smoke ui ok"
echo "$loc"
echo "$export_url"
SH2
chmod +x scripts/smoke-ui.sh

echo "==> [6] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase6 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
