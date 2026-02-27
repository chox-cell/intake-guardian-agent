#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase10 OneShot (UI hardfix: tickets route + admin autolink without admin API) @ $(pwd)"

TS=$(date +"%Y%m%d_%H%M%S")
BAK="__bak_phase10_${TS}"
mkdir -p "$BAK"
cp -R src scripts tsconfig.json "$BAK" 2>/dev/null || true
echo "✅ backup -> $BAK"

echo "==> [1] Ensure tsconfig excludes backups"
node <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
if (!fs.existsSync(p)) process.exit(0);
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]), "__bak_*", "src/__bak_*", "scripts/__bak_*"]));
fs.writeFileSync(p, JSON.stringify(j,null,2));
console.log("✅ patched tsconfig.json exclude");
NODE

echo "==> [2] Write src/ui/routes.ts (full UI: /ui hidden, /ui/admin autolink, /ui/tickets, export, demo)"
mkdir -p src/ui
cat > src/ui/routes.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import type { Express, Request, Response } from "express";

// We only use your existing tenant-key gate (contract: throws {status,message} on fail)
import { requireTenantKey } from "../api/tenant-key.js";

type AnyStore = any;

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function nowIso() {
  return new Date().toISOString();
}

function b64url(buf: Buffer) {
  return buf.toString("base64").replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function getDataDir() {
  return process.env.DATA_DIR || "./data";
}

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function adminTenantsPath() {
  return path.join(getDataDir(), "admin.tenants.json");
}

function loadAdminTenants(): { ok: true; tenants: Array<{ tenantId: string; tenantKey: string; createdAt: string }> } {
  const p = adminTenantsPath();
  ensureDir(path.dirname(p));
  if (!fs.existsSync(p)) {
    const init = { ok: true, tenants: [] as any[] };
    fs.writeFileSync(p, JSON.stringify(init, null, 2));
  }
  try {
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    if (j && Array.isArray(j.tenants)) return { ok: true, tenants: j.tenants };
  } catch {}
  return { ok: true, tenants: [] };
}

function saveAdminTenants(tenants: Array<{ tenantId: string; tenantKey: string; createdAt: string }>) {
  const p = adminTenantsPath();
  ensureDir(path.dirname(p));
  fs.writeFileSync(p, JSON.stringify({ ok: true, tenants }, null, 2));
}

function createTenant(): { tenantId: string; tenantKey: string } {
  const id = `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
  const key = b64url(crypto.randomBytes(24));
  const state = loadAdminTenants();
  state.tenants.unshift({ tenantId: id, tenantKey: key, createdAt: nowIso() });
  // keep last 500 max
  state.tenants = state.tenants.slice(0, 500);
  saveAdminTenants(state.tenants);
  return { tenantId: id, tenantKey: key };
}

function isAdminOk(req: Request) {
  const admin = (req.query.admin as string) || req.header("x-admin-key") || "";
  const ADMIN_KEY = process.env.ADMIN_KEY || "";
  if (!ADMIN_KEY) return { ok: false as const, error: "admin_key_not_configured" };
  if (!admin) return { ok: false as const, error: "missing_admin_key" };
  if (admin !== ADMIN_KEY) return { ok: false as const, error: "invalid_admin_key" };
  return { ok: true as const };
}

type Ticket = {
  id: string;
  subject: string;
  sender: string;
  status: "open" | "triage" | "waiting" | "closed";
  priority: "low" | "med" | "high";
  due: string;
  createdAt: string;
  updatedAt: string;
};

function ticketsPath(tenantId: string) {
  return path.join(getDataDir(), "tenants", tenantId, "tickets.json");
}

function loadTickets(tenantId: string): Ticket[] {
  const p = ticketsPath(tenantId);
  ensureDir(path.dirname(p));
  if (!fs.existsSync(p)) fs.writeFileSync(p, JSON.stringify({ ok: true, tickets: [] }, null, 2));
  try {
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    if (j && Array.isArray(j.tickets)) return j.tickets;
  } catch {}
  return [];
}

function saveTickets(tenantId: string, tickets: Ticket[]) {
  const p = ticketsPath(tenantId);
  ensureDir(path.dirname(p));
  fs.writeFileSync(p, JSON.stringify({ ok: true, tickets }, null, 2));
}

function csvEscape(v: any) {
  const s = String(v ?? "");
  if (/[,"\n]/.test(s)) return `"${s.replaceAll('"', '""')}"`;
  return s;
}

function layout(title: string, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${esc(title)}</title>
<style>
:root{color-scheme:dark}
body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1200px 800px at 30% 20%,#0b1633 0%,#05070c 65%);color:#e5e7eb}
.wrap{max-width:1100px;margin:48px auto;padding:0 18px}
.card{border:1px solid rgba(255,255,255,.08);background:rgba(17,24,39,.55);border-radius:18px;padding:18px 18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
.h{font-size:22px;font-weight:800;margin:0 0 6px}
.muted{color:#9ca3af;font-size:13px}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
.btn{display:inline-flex;align-items:center;gap:8px;padding:10px 12px;border-radius:12px;border:1px solid rgba(255,255,255,.10);background:rgba(2,6,23,.4);color:#e5e7eb;text-decoration:none;font-weight:700;font-size:13px}
.btn:hover{background:rgba(2,6,23,.6)}
.btn.primary{background:rgba(59,130,246,.22);border-color:rgba(59,130,246,.35)}
.btn.ok{background:rgba(34,197,94,.18);border-color:rgba(34,197,94,.30)}
.in{padding:10px 12px;border-radius:12px;border:1px solid rgba(255,255,255,.10);background:rgba(2,6,23,.35);color:#e5e7eb;min-width:240px}
.table{width:100%;border-collapse:separate;border-spacing:0;margin-top:12px;overflow:hidden;border-radius:14px;border:1px solid rgba(255,255,255,.08)}
th,td{padding:10px 10px;font-size:13px;border-bottom:1px solid rgba(255,255,255,.06)}
th{color:#9ca3af;text-transform:uppercase;letter-spacing:.12em;font-size:11px}
tr:last-child td{border-bottom:none}
.badge{padding:4px 8px;border-radius:999px;border:1px solid rgba(255,255,255,.10);font-size:12px;color:#e5e7eb;background:rgba(0,0,0,.25)}
pre{white-space:pre-wrap;word-break:break-word;background:rgba(0,0,0,.35);border:1px solid rgba(255,255,255,.08);padding:12px;border-radius:12px}
hr{border:0;border-top:1px solid rgba(255,255,255,.08);margin:14px 0}
</style>
</head>
<body>
<div class="wrap">${body}</div>
</body>
</html>`;
}

export function mountUi(app: Express, args: { store?: AnyStore }) {
  // 1) Hide root /ui (no landing page)
  app.get("/ui", (_req, res) => res.status(404).send(""));

  // 2) Admin autolink: generates tenant+key directly, then redirects to client link
  app.get("/ui/admin", (req, res) => {
    const ok = isAdminOk(req);
    if (!ok.ok) {
      const html = layout("Admin error", `
        <div class="card">
          <div class="h">Admin error</div>
          <div class="muted">${esc(ok.error)}</div>
          <pre>Fix: run server with ADMIN_KEY set. Example:
ADMIN_KEY=super_secret_admin_123 pnpm dev</pre>
          <div class="muted" style="margin-top:10px">Intake-Guardian • ${esc(nowIso())}</div>
        </div>
      `);
      return res.status(401).send(html);
    }

    const { tenantId, tenantKey } = createTenant();
    const link = `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;
    return res.redirect(302, link);
  });

  // Helper: gate tenantKey (throws {status,message})
  function gate(req: Request, res: Response, tenantId: string) {
    try {
      requireTenantKey(req as any, tenantId);
      return true;
    } catch (e: any) {
      const status = Number(e?.status || 401);
      const msg = String(e?.message || "invalid_tenant_key");
      const html = layout("Unauthorized", `
        <div class="card">
          <div class="h">Unauthorized</div>
          <div class="muted">Bad tenant key or missing.</div>
          <pre>${esc(msg)}</pre>
        </div>
      `);
      res.status(status).send(html);
      return false;
    }
  }

  // 3) Tickets UI
  app.get("/ui/tickets", (req, res) => {
    const tenantId = String(req.query.tenantId || "");
    const k = String(req.query.k || "");
    if (!tenantId) return res.status(400).send("missing tenantId");
    if (!gate(req, res, tenantId)) return;

    const tickets = loadTickets(tenantId);
    const rows = tickets
      .map(t => `
        <tr>
          <td>${esc(t.id)}</td>
          <td>${esc(t.subject)}<div class="muted">${esc(t.sender)}</div></td>
          <td><span class="badge">${esc(t.status)}</span></td>
          <td><span class="badge">${esc(t.priority)}</span></td>
          <td class="muted">${esc(t.due)}</td>
          <td>
            <form method="post" action="/ui/status" style="display:flex;gap:8px;align-items:center;margin:0">
              <input type="hidden" name="tenantId" value="${esc(tenantId)}" />
              <input type="hidden" name="k" value="${esc(k)}" />
              <input type="hidden" name="id" value="${esc(t.id)}" />
              <select class="in" name="status" style="min-width:140px">
                ${["open","triage","waiting","closed"].map(s => `<option value="${s}" ${t.status===s?"selected":""}>${s}</option>`).join("")}
              </select>
              <button class="btn ok" type="submit">Save</button>
            </form>
          </td>
        </tr>
      `)
      .join("");

    const clientLink = `${req.protocol}://${req.get("host")}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
    const exportLink = `/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;

    const html = layout("Tickets", `
      <div class="card">
        <div class="row" style="justify-content:space-between">
          <div>
            <div class="h">Tickets</div>
            <div class="muted">tenant: <b>${esc(tenantId)}</b> • total: ${tickets.length}</div>
          </div>
          <div class="row">
            <a class="btn primary" href="/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}">Refresh</a>
            <a class="btn ok" href="${exportLink}">Export CSV</a>
          </div>
        </div>

        <hr/>

        <div class="muted">Share with your client (no login):</div>
        <div class="row" style="margin-top:8px">
          <input class="in" style="flex:1;min-width:320px" value="${esc(clientLink)}" readonly />
        </div>

        <hr/>

        <div class="row">
          <form method="post" action="/ui/demo" style="margin:0">
            <input type="hidden" name="tenantId" value="${esc(tenantId)}" />
            <input type="hidden" name="k" value="${esc(k)}" />
            <button class="btn primary" type="submit">Create demo ticket</button>
          </form>
          <a class="btn" href="${exportLink}">Download CSV</a>
        </div>

        <table class="table">
          <thead>
            <tr>
              <th>ID</th><th>Subject / Sender</th><th>Status</th><th>Priority</th><th>SLA / Due</th><th>Actions</th>
            </tr>
          </thead>
          <tbody>
            ${tickets.length ? rows : `<tr><td colspan="6" class="muted">No tickets yet. Click “Create demo ticket”.</td></tr>`}
          </tbody>
        </table>

        <div class="muted" style="margin-top:10px">Intake-Guardian • ${esc(nowIso())}</div>
      </div>
    `);

    res.status(200).send(html);
  });

  // 4) Create demo ticket (UI only)
  app.post("/ui/demo", (req: any, res) => {
    const tenantId = String(req.body?.tenantId || req.query.tenantId || "");
    const k = String(req.body?.k || req.query.k || "");
    if (!tenantId) return res.status(400).send("missing tenantId");
    if (!gate(req, res, tenantId)) return;

    const tickets = loadTickets(tenantId);
    const id = `t_${Date.now().toString(36)}`;
    const t: Ticket = {
      id,
      subject: "VPN broken (demo)",
      sender: "employee@corp.local",
      status: "open",
      priority: "high",
      due: new Date(Date.now() + 1000 * 60 * 60 * 24).toISOString().slice(0, 10),
      createdAt: nowIso(),
      updatedAt: nowIso(),
    };
    tickets.unshift(t);
    saveTickets(tenantId, tickets);
    res.redirect(302, `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`);
  });

  // 5) Update status
  app.post("/ui/status", (req: any, res) => {
    const tenantId = String(req.body?.tenantId || "");
    const k = String(req.body?.k || "");
    const id = String(req.body?.id || "");
    const status = String(req.body?.status || "");
    if (!tenantId || !id) return res.status(400).send("missing");
    if (!gate(req, res, tenantId)) return;

    const tickets = loadTickets(tenantId);
    const idx = tickets.findIndex(t => t.id === id);
    if (idx >= 0) {
      tickets[idx].status = (["open","triage","waiting","closed"].includes(status) ? (status as any) : tickets[idx].status);
      tickets[idx].updatedAt = nowIso();
      saveTickets(tenantId, tickets);
    }
    res.redirect(302, `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`);
  });

  // 6) Export CSV
  app.get("/ui/export.csv", (req, res) => {
    const tenantId = String(req.query.tenantId || "");
    if (!tenantId) return res.status(400).send("missing tenantId");
    try {
      requireTenantKey(req as any, tenantId);
    } catch {
      return res.status(401).send("unauthorized");
    }

    const tickets = loadTickets(tenantId);
    const header = ["id","subject","sender","status","priority","due","createdAt","updatedAt"].join(",");
    const lines = tickets.map(t =>
      [
        csvEscape(t.id),
        csvEscape(t.subject),
        csvEscape(t.sender),
        csvEscape(t.status),
        csvEscape(t.priority),
        csvEscape(t.due),
        csvEscape(t.createdAt),
        csvEscape(t.updatedAt),
      ].join(",")
    );
    const csv = [header, ...lines].join("\n") + "\n";

    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    res.status(200).send(csv);
  });
}
TS

echo "==> [3] Ensure scripts: demo-keys + smoke-ui (admin autolink -> client link) (no python)"
mkdir -p scripts

cat > scripts/demo-keys.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-${1:-}}"
if [[ -z "${ADMIN_KEY}" ]]; then
  echo "missing ADMIN_KEY. Usage:"
  echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=$BASE_URL ./scripts/demo-keys.sh"
  exit 1
fi

echo "==> Open admin autolink (will redirect to client UI)"
echo "$BASE_URL/ui/admin?admin=$ADMIN_KEY"
echo

echo "==> Resolve redirect -> client link"
LOC=$(curl -sS -D - "$BASE_URL/ui/admin?admin=$ADMIN_KEY" -o /dev/null | awk 'BEGIN{IGNORECASE=1} $1=="Location:"{print $2}' | tr -d '\r' | tail -n1)
if [[ -z "${LOC}" ]]; then
  echo "❌ no Location header"
  curl -sS "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | head -n 60
  exit 2
fi

if [[ "${LOC}" == /* ]]; then
  echo "✅ client link:"
  echo "$BASE_URL${LOC}"
else
  echo "✅ client link:"
  echo "${LOC}"
fi
BASH
chmod +x scripts/demo-keys.sh

cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-${1:-}}"
if [[ -z "${ADMIN_KEY}" ]]; then
  echo "missing ADMIN_KEY. Usage:"
  echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=$BASE_URL ./scripts/smoke-ui.sh"
  exit 1
fi

echo "==> [1] /ui hidden (404)"
S=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui")
echo "status=$S"
[[ "$S" == "404" ]] || { echo "FAIL expected 404"; exit 2; }

echo "==> [2] /ui/admin redirect (302)"
H=$(curl -sS -D - "$BASE_URL/ui/admin?admin=$ADMIN_KEY" -o /dev/null)
CODE=$(echo "$H" | head -n1 | awk '{print $2}')
echo "status=$CODE"
[[ "$CODE" == "302" ]] || { echo "FAIL expected 302"; echo "$H" | head -n 20; exit 3; }

LOC=$(echo "$H" | awk 'BEGIN{IGNORECASE=1} $1=="Location:"{print $2}' | tr -d '\r' | tail -n1)
[[ -n "$LOC" ]] || { echo "FAIL missing Location"; exit 4; }

if [[ "$LOC" == /* ]]; then
  TICKETS="$BASE_URL$LOC"
else
  TICKETS="$LOC"
fi

echo "==> [3] client tickets should be 200"
CODE2=$(curl -sS -o /dev/null -w "%{http_code}" "$TICKETS")
echo "status=$CODE2"
[[ "$CODE2" == "200" ]] || { echo "FAIL expected 200"; echo "$TICKETS"; exit 5; }

echo "==> [4] export csv should be 200"
CSV="${TICKETS/\/ui\/tickets/\/ui\/export.csv}"
CODE3=$(curl -sS -o /dev/null -w "%{http_code}" "$CSV")
echo "status=$CODE3"
[[ "$CODE3" == "200" ]] || { echo "FAIL expected 200"; echo "$CSV"; exit 6; }

echo "✅ smoke ok"
echo "client_ui: $TICKETS"
BASH
chmod +x scripts/smoke-ui.sh

echo "==> [4] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase10 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
