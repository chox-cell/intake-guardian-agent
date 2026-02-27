#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase6g_${ts}"
mkdir -p "$bak"
cp -R src "$bak/src" 2>/dev/null || true
cp -R scripts "$bak/scripts" 2>/dev/null || true

echo "==> Phase6g OneShot (accept ?admin + ?ak + header; safer /ui/admin) @ $ROOT"
echo "==> [0] Backup -> $bak"

mkdir -p src/ui scripts

echo "==> [1] Overwrite src/ui/routes.ts (admin key compatibility + clean errors)"
cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";

type AnyStore = {
  listWorkItems?: (tenantId: string, q: any) => Promise<any[]>;
  verifyTenantKey?: (tenantId: string, key: string) => boolean;
};
type AnyTenants = {
  verifyTenantKey?: (tenantId: string, key: string) => boolean;
};

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function getBaseUrl(req: Request) {
  const envBase = process.env.PUBLIC_BASE_URL || "";
  if (envBase) return envBase.replace(/\/+$/, "");

  const proto = (req.headers["x-forwarded-proto"] as string) || req.protocol || "http";
  const host = (req.headers["x-forwarded-host"] as string) || (req.headers.host as string) || "";
  if (host) return `${proto}://${host}`;

  const port = process.env.PORT || "7090";
  return `http://127.0.0.1:${port}`;
}

function getAdminKey(req: Request) {
  const h = (req.headers["x-admin-key"] as string) || "";
  const q1 = typeof req.query.ak === "string" ? req.query.ak : "";
  const q2 = typeof req.query.admin === "string" ? req.query.admin : "";
  return h || q1 || q2;
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

function mustTenantKey(req: Request, tenantId: string, tenants: AnyTenants, store: AnyStore) {
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

function renderClientPage(args: { tenantId: string; key: string; items: any[]; baseUrl: string }) {
  const { tenantId, key, items, baseUrl } = args;
  const exportUrl = `${baseUrl}/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(key)}`;

  const rows = (items || []).map((it: any) => `
    <tr>
      <td class="mono">${esc(it.id)}</td>
      <td>${esc(it.subject || "")}</td>
      <td>${esc(it.sender || "")}</td>
      <td><span class="pill">${esc(it.status || "")}</span></td>
      <td><span class="pill">${esc(it.priority || "")}</span></td>
      <td class="mono">${esc(it.createdAt || "")}</td>
    </tr>
  `).join("");

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Tickets</title>
  <style>
    body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial;margin:0;background:#0b1220;color:#e8eefc}
    .wrap{max-width:1100px;margin:0 auto;padding:22px}
    .card{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.12);border-radius:16px;padding:16px}
    h1{margin:0 0 8px;font-size:20px}
    .muted{color:rgba(232,238,252,.72);font-size:13px}
    .row{display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin-top:12px}
    a.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:10px 12px;border-radius:12px;
      text-decoration:none;border:1px solid rgba(255,255,255,.14);background:rgba(255,255,255,.08);color:#e8eefc;font-weight:700;font-size:13px}
    a.btn:hover{background:rgba(255,255,255,.12)}
    table{width:100%;border-collapse:collapse;margin-top:14px;border-radius:12px;overflow:hidden}
    th,td{padding:10px;border-bottom:1px solid rgba(255,255,255,.10);font-size:13px}
    th{background:rgba(255,255,255,.06);text-align:left;color:rgba(232,238,252,.75)}
    .pill{padding:4px 8px;border-radius:999px;background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.12);font-size:12px}
    .mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:12px}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Tickets</h1>
      <div class="muted">tenantId: <span class="mono">${esc(tenantId)}</span></div>

      <div class="row">
        <a class="btn" href="${exportUrl}">⬇️ Export CSV</a>
        <a class="btn" target="_blank" rel="noreferrer"
           href="https://wa.me/?text=${encodeURIComponent("Hello, I need help. Tenant: "+tenantId)}">💬 WhatsApp</a>
        <a class="btn" href="${baseUrl}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(key)}">🔄 Refresh</a>
      </div>

      <table>
        <thead><tr><th>ID</th><th>Subject</th><th>Sender</th><th>Status</th><th>Priority</th><th>Created</th></tr></thead>
        <tbody>
          ${rows || `<tr><td colspan="6" class="muted">No tickets yet.</td></tr>`}
        </tbody>
      </table>
    </div>
  </div>
</body>
</html>`;
}

export function mountUi(app: Express, args: { store: AnyStore; tenants: AnyTenants }) {
  const store = args.store;
  const tenants = args.tenants;

  // hide /ui root
  app.get("/ui", (_req, res) => res.status(404).send("not_found"));

  // admin autolink -> call existing API then redirect
  app.get("/ui/admin", async (req: Request, res: Response) => {
    try {
      const ak = mustAdmin(req);
      const baseUrl = getBaseUrl(req);

      let r: any;
      try {
        r = await fetch(`${baseUrl}/api/admin/tenants/create`, {
          method: "POST",
          headers: { "x-admin-key": ak, "content-type": "application/json" },
          body: "{}",
        });
      } catch (netErr: any) {
        res.status(502).send(`<pre>admin_autolink_fetch_failed\n${esc(netErr?.message || netErr)}</pre>`);
        return;
      }

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
      res.status(Number(e?.status || 401)).send(`<pre>${esc(e?.message || "admin_denied")}</pre>`);
    }
  });

  // client UI
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

  // export
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

echo "==> [2] Rewrite scripts/demo-keys.sh to use ?admin= (your current habit)"
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

echo "==> Open admin autolink (will redirect to client UI)"
echo "$BASE_URL/ui/admin?admin=$ADMIN_KEY"
open "$BASE_URL/ui/admin?admin=$ADMIN_KEY" || true

echo
echo "==> Show headers (expect 302 + Location)"
curl -sS -I "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | sed -n '1,30p'
SH2
chmod +x scripts/demo-keys.sh

echo "==> [3] Patch scripts/smoke-ui.sh to print body on failure"
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

echo "==> [2] /ui/admin redirect (302 expected)"
s2="$(curl -sS -o /dev/null -w '%{http_code}' -I "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
echo "status=$s2"
if [[ "$s2" != "302" ]]; then
  echo "---- debug headers ----"
  curl -sS -I "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | sed -n '1,40p'
  echo "---- debug body (first lines) ----"
  curl -sS "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | sed -n '1,80p'
  exit 1
fi

loc="$(curl -sS -I "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r\n')"
echo "location=$loc"

echo "==> [3] client page (200)"
s3="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL$loc")"
echo "status=$s3"
[[ "$s3" == "200" ]] || { echo "FAIL: expected 200"; exit 1; }

echo "==> [4] export (200)"
tenantId="$(echo "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
k="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
exp="$BASE_URL/ui/export.csv?tenantId=$tenantId&k=$k"
s4="$(curl -sS -o /dev/null -w '%{http_code}' -I "$exp")"
echo "status=$s4"
[[ "$s4" == "200" ]] || { echo "FAIL: expected 200"; exit 1; }

echo "✅ smoke ok"
echo "client_ui: $BASE_URL$loc"
echo "export:    $exp"
SH2
chmod +x scripts/smoke-ui.sh

echo "==> [4] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase6g installed."
echo "Now:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
