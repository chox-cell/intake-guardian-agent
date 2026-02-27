#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase21_${ts}"
mkdir -p "$bak"
echo "==> Phase21 OneShot (Webhook Intake + Persistent Tickets) @ $ROOT"
echo "✅ backup -> $bak"
cp -R src scripts package.json tsconfig.json "$bak" 2>/dev/null || true

# --- [1] Ensure tsconfig excludes backups ---
if [ -f tsconfig.json ]; then
  node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]), "__bak_*"]));
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
console.log("✅ patched tsconfig.json exclude");
NODE
fi

# --- [2] Write persistent ticket store ---
mkdir -p src/lib
cat > src/lib/ticket_store.ts <<'TS'
import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

export type TicketStatus = "open" | "pending" | "closed";
export type TicketPriority = "low" | "medium" | "high";

export type Ticket = {
  id: string;
  tenantId: string;
  subject: string;
  sender: string;
  body?: string;
  status: TicketStatus;
  priority: TicketPriority;
  due?: string | null;
  createdAt: string;
  updatedAt: string;
};

function dataDir() {
  // repo-root/data/...
  return path.join(process.cwd(), "data");
}

function tenantDir(tenantId: string) {
  return path.join(dataDir(), "tenants", tenantId);
}

function ticketsFile(tenantId: string) {
  return path.join(tenantDir(tenantId), "tickets.json");
}

async function ensureTenantDir(tenantId: string) {
  await fs.mkdir(tenantDir(tenantId), { recursive: true });
}

async function readJsonSafe<T>(file: string, fallback: T): Promise<T> {
  try {
    const s = await fs.readFile(file, "utf8");
    return JSON.parse(s) as T;
  } catch {
    return fallback;
  }
}

async function writeJsonAtomic(file: string, value: unknown) {
  const tmp = `${file}.tmp.${Date.now()}`;
  const s = JSON.stringify(value, null, 2) + "\n";
  await fs.writeFile(tmp, s, "utf8");
  await fs.rename(tmp, file);
}

export async function listTickets(tenantId: string): Promise<Ticket[]> {
  await ensureTenantDir(tenantId);
  const items = await readJsonSafe<Ticket[]>(ticketsFile(tenantId), []);
  // newest first
  return items.sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1));
}

export async function addTicket(
  tenantId: string,
  input: Partial<Pick<Ticket, "subject" | "sender" | "body" | "priority" | "due" | "status">>
): Promise<Ticket> {
  if (!tenantId) throw new Error("tenantId_required");
  const subject = (input.subject || "").trim() || "New request";
  const sender = (input.sender || "").trim() || "unknown@example.com";

  const now = new Date().toISOString();
  const id = `t_${Date.now()}_${crypto.randomBytes(4).toString("hex")}`;

  const ticket: Ticket = {
    id,
    tenantId,
    subject,
    sender,
    body: input.body || "",
    status: (input.status as any) || "open",
    priority: (input.priority as any) || "medium",
    due: input.due ?? null,
    createdAt: now,
    updatedAt: now,
  };

  await ensureTenantDir(tenantId);
  const file = ticketsFile(tenantId);
  const items = await readJsonSafe<Ticket[]>(file, []);
  items.push(ticket);
  await writeJsonAtomic(file, items);

  return ticket;
}

export async function updateTicket(
  tenantId: string,
  id: string,
  patch: Partial<Pick<Ticket, "status" | "priority" | "due" | "subject" | "sender" | "body">>
): Promise<Ticket | null> {
  await ensureTenantDir(tenantId);
  const file = ticketsFile(tenantId);
  const items = await readJsonSafe<Ticket[]>(file, []);
  const idx = items.findIndex((t) => t.id === id);
  if (idx === -1) return null;

  const now = new Date().toISOString();
  const cur = items[idx];
  const next: Ticket = {
    ...cur,
    ...patch,
    updatedAt: now,
  };
  items[idx] = next;
  await writeJsonAtomic(file, items);
  return next;
}

function csvEscape(v: string) {
  const s = (v ?? "").toString();
  if (s.includes('"') || s.includes(",") || s.includes("\n") || s.includes("\r")) {
    return `"${s.replaceAll('"', '""')}"`;
  }
  return s;
}

export function ticketsToCsv(rows: Ticket[]): string {
  const head = ["id","subject","sender","status","priority","due","createdAt","updatedAt"];
  const lines = [head.join(",")];
  for (const t of rows) {
    lines.push([
      csvEscape(t.id),
      csvEscape(t.subject),
      csvEscape(t.sender),
      csvEscape(t.status),
      csvEscape(t.priority),
      csvEscape(t.due || ""),
      csvEscape(t.createdAt),
      csvEscape(t.updatedAt),
    ].join(","));
  }
  return lines.join("\n") + "\n";
}
TS
echo "✅ wrote src/lib/ticket_store.ts"

# --- [3] Ensure tenant registry exists + compatible verify ---
mkdir -p src/lib
cat > src/lib/tenant_registry.ts <<'TS'
import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

export type TenantRecord = {
  tenantId: string;
  tenantKey: string; // secret for client links + webhook auth
  createdAt: string;
  label?: string;
};

function dataDir() {
  return path.join(process.cwd(), "data");
}
function filePath() {
  return path.join(dataDir(), "tenant_registry.json");
}
async function ensureDir() {
  await fs.mkdir(dataDir(), { recursive: true });
}
async function readSafe(): Promise<{ ok: true; tenants: TenantRecord[] }> {
  await ensureDir();
  try {
    const s = await fs.readFile(filePath(), "utf8");
    const j = JSON.parse(s);
    const tenants = Array.isArray(j.tenants) ? j.tenants : [];
    return { ok: true, tenants };
  } catch {
    return { ok: true, tenants: [] };
  }
}
async function writeAtomic(payload: { ok: true; tenants: TenantRecord[] }) {
  await ensureDir();
  const tmp = `${filePath()}.tmp.${Date.now()}`;
  await fs.writeFile(tmp, JSON.stringify(payload, null, 2) + "\n", "utf8");
  await fs.rename(tmp, filePath());
}

export async function listTenants(): Promise<TenantRecord[]> {
  const j = await readSafe();
  return j.tenants;
}

export async function createTenant(label?: string): Promise<TenantRecord> {
  const now = new Date().toISOString();
  const tenantId = `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
  const tenantKey = crypto.randomBytes(24).toString("base64url");
  const rec: TenantRecord = { tenantId, tenantKey, createdAt: now, label };
  const j = await readSafe();
  j.tenants.push(rec);
  await writeAtomic(j);
  return rec;
}

export async function getOrCreateDemoTenant(): Promise<TenantRecord> {
  const DEMO_ID = "tenant_demo_local";
  const j = await readSafe();
  const found = j.tenants.find(t => t.tenantId === DEMO_ID);
  if (found) return found;

  const now = new Date().toISOString();
  const rec: TenantRecord = {
    tenantId: DEMO_ID,
    tenantKey: crypto.randomBytes(24).toString("base64url"),
    createdAt: now,
    label: "Demo (local)",
  };
  j.tenants.push(rec);
  await writeAtomic(j);
  return rec;
}

// Backward compatible: accept (tenantId,k) OR ({tenantId,k}) — callers vary across phases
export function verifyTenantKeyLocal(arg1: any, arg2?: any): boolean {
  // (tenantId, key)
  if (typeof arg1 === "string") {
    const tenantId = arg1;
    const k = (arg2 ?? "").toString();
    return verifySync(tenantId, k);
  }
  // ({tenantId, k})
  if (arg1 && typeof arg1 === "object") {
    const tenantId = (arg1.tenantId ?? "").toString();
    const k = (arg1.k ?? arg1.tenantKey ?? "").toString();
    return verifySync(tenantId, k);
  }
  return false;
}

// sync read for ultra-hot path only (used in UI/auth). Falls back to false if file not present.
function verifySync(tenantId: string, k: string): boolean {
  try {
    const p = filePath();
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const fsSync = require("node:fs");
    if (!fsSync.existsSync(p)) return false;
    const s = fsSync.readFileSync(p, "utf8");
    const j = JSON.parse(s);
    const tenants = Array.isArray(j.tenants) ? j.tenants : [];
    const t = tenants.find((x: any) => x.tenantId === tenantId);
    return !!t && t.tenantKey === k;
  } catch {
    return false;
  }
}
TS
echo "✅ wrote src/lib/tenant_registry.ts"

# --- [4] Patch UI routes (adds /intake webhook + persistent tickets) ---
mkdir -p src/ui
cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";
import express from "express";
import { verifyTenantKeyLocal, getOrCreateDemoTenant, createTenant } from "../lib/tenant_registry.js";
import { addTicket, listTickets, ticketsToCsv, updateTicket } from "../lib/ticket_store.js";
import { mountLanding } from "./landing.js";

function htmlPage(title: string, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${title}</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial; background: radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%); color:#e5e7eb; }
  .wrap { max-width: 1180px; margin: 56px auto; padding: 0 18px; }
  .card { border:1px solid rgba(255,255,255,.08); background: rgba(17,24,39,.55); border-radius: 18px; padding: 18px 18px; box-shadow: 0 18px 60px rgba(0,0,0,.35); }
  .h { font-size: 28px; font-weight: 850; margin: 0 0 10px; letter-spacing: .2px; }
  .muted { color: #9ca3af; font-size: 13px; }
  .row { display:flex; gap:14px; flex-wrap:wrap; align-items:center; }
  .btn { display:inline-block; padding:10px 14px; border-radius: 12px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.25); color:#e5e7eb; text-decoration:none; font-weight:700; }
  .btn:hover { border-color: rgba(255,255,255,.18); background: rgba(0,0,0,.34); }
  .btn.primary { background: rgba(34,197,94,.16); border-color: rgba(34,197,94,.30); }
  .btn.primary:hover { background: rgba(34,197,94,.22); }
  table { width:100%; border-collapse: collapse; margin-top: 12px; }
  th, td { text-align:left; padding: 10px 10px; border-bottom: 1px solid rgba(255,255,255,.06); font-size: 13px; }
  th { color:#9ca3af; font-weight: 800; font-size: 12px; letter-spacing: .08em; text-transform: uppercase; }
  .chip { display:inline-block; padding: 4px 10px; border-radius: 999px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.20); font-weight: 800; font-size: 12px; }
  .chip.open { border-color: rgba(59,130,246,.35); background: rgba(59,130,246,.12); }
  .chip.pending { border-color: rgba(245,158,11,.35); background: rgba(245,158,11,.12); }
  .chip.closed { border-color: rgba(34,197,94,.35); background: rgba(34,197,94,.12); }
  .kbd { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; font-size: 12px; padding: 3px 8px; border-radius: 10px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.30); color:#e5e7eb; }
  pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
</style>
</head>
<body>
  <div class="wrap">
    ${body}
  </div>
</body>
</html>`;
}

function bad(res: Response, title: string, msg: string, detail?: any, code = 500) {
  const b = htmlPage(title, `
    <div class="card">
      <div class="h">${title}</div>
      <div class="muted">${msg}</div>
      ${detail ? `<pre>${escapeHtml(typeof detail === "string" ? detail : JSON.stringify(detail, null, 2))}</pre>` : ""}
      <div class="muted" style="margin-top:10px">Intake-Guardian • ${new Date().toISOString()}</div>
    </div>
  `);
  res.status(code).type("text/html").send(b);
}

function escapeHtml(s: string) {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function constantTimeEq(a: string, b: string) {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  // @ts-ignore
  return require("node:crypto").timingSafeEqual(ab, bb);
}

function getTenantId(req: Request) {
  return (req.query.tenantId || req.query.t || "").toString();
}
function getTenantKey(req: Request) {
  const q = (req.query.k || "").toString();
  const h = (req.headers["x-tenant-key"] || req.headers["x-tenantkey"] || "").toString();
  return q || h;
}

async function requireTenant(req: Request, res: Response): Promise<{ tenantId: string; k: string } | null> {
  const tenantId = getTenantId(req);
  const k = getTenantKey(req);
  if (!tenantId || !k) {
    bad(res, "Unauthorized", "Bad tenant key or missing.", "invalid_tenant_key", 401);
    return null;
  }
  // local verify
  if (!verifyTenantKeyLocal(tenantId, k)) {
    bad(res, "Unauthorized", "Bad tenant key or missing.", "invalid_tenant_key", 401);
    return null;
  }
  return { tenantId, k };
}

async function renderTickets(req: Request, res: Response) {
  const auth = await requireTenant(req, res);
  if (!auth) return;

  const rows = await listTickets(auth.tenantId);

  const body = `
  <div class="card">
    <div class="h">Tickets</div>
    <div class="muted">tenant: <span class="kbd">${escapeHtml(auth.tenantId)}</span></div>
    <div class="row" style="margin-top:12px">
      <a class="btn" href="/ui/tickets?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}">Refresh</a>
      <a class="btn primary" href="/ui/export.csv?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}">Export CSV</a>
      <a class="btn" href="/ui/demo-ticket?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}">Create demo ticket</a>
      <a class="btn" href="#" onclick="navigator.clipboard.writeText(window.location.href); return false;">Copy link</a>
    </div>

    <table>
      <thead>
        <tr>
          <th>ID</th>
          <th>Subject / Sender</th>
          <th>Status</th>
          <th>Priority</th>
          <th>Due</th>
          <th>Created</th>
        </tr>
      </thead>
      <tbody>
        ${
          rows.length === 0
            ? `<tr><td colspan="6" class="muted">No tickets yet. Send a webhook or use demo.</td></tr>`
            : rows
                .map(
                  (t) => `<tr>
                    <td class="kbd">${escapeHtml(t.id)}</td>
                    <td>
                      <div style="font-weight:800">${escapeHtml(t.subject)}</div>
                      <div class="muted">${escapeHtml(t.sender)}</div>
                    </td>
                    <td><span class="chip ${escapeHtml(t.status)}">${escapeHtml(t.status)}</span></td>
                    <td>${escapeHtml(t.priority)}</td>
                    <td>${escapeHtml(t.due || "")}</td>
                    <td>${escapeHtml(new Date(t.createdAt).toLocaleString())}</td>
                  </tr>`
                )
                .join("")
        }
      </tbody>
    </table>

    <div class="muted" style="margin-top:10px">
      Intake-Guardian — one place to see requests, change status, export proof.
    </div>
    <div class="muted" style="margin-top:6px">
      Webhook: <span class="kbd">POST /intake/${escapeHtml(auth.tenantId)}?k=${escapeHtml(auth.k)}</span>
      (or header <span class="kbd">x-tenant-key</span>)
    </div>
    <div class="muted" style="margin-top:10px">Intake-Guardian • ${new Date().toISOString()}</div>
  </div>
  `;
  res.status(200).type("text/html").send(htmlPage("Tickets", body));
}

async function exportCsv(req: Request, res: Response) {
  const auth = await requireTenant(req, res);
  if (!auth) return;
  const rows = await listTickets(auth.tenantId);
  const csv = ticketsToCsv(rows);
  res.status(200);
  res.setHeader("Content-Type", "text/csv; charset=utf-8");
  res.setHeader("Content-Disposition", `attachment; filename="tickets_${auth.tenantId}.csv"`);
  res.send(csv);
}

async function demoTicket(req: Request, res: Response) {
  const auth = await requireTenant(req, res);
  if (!auth) return;

  await addTicket(auth.tenantId, {
    subject: "New request: Onboarding question",
    sender: "client@example.com",
    body: "Hello — can you onboard us and share next steps?",
    priority: "medium",
    status: "open",
  });

  res.redirect(302, `/ui/tickets?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}`);
}

/**
 * Webhook Intake (REAL):
 * POST /intake/:tenantId?k=TENANT_KEY
 * header alternative: x-tenant-key: TENANT_KEY
 *
 * payload:
 * {
 *  subject, sender, body, priority, due, status
 * }
 */
async function webhookIntake(req: Request, res: Response) {
  const tenantId = (req.params.tenantId || "").toString();
  const k = (req.query.k || req.headers["x-tenant-key"] || req.headers["x-tenantkey"] || "").toString();

  if (!tenantId || !k || !verifyTenantKeyLocal(tenantId, k)) {
    return res.status(401).json({ ok: false, error: "invalid_tenant_key" });
  }

  const body = (req.body && typeof req.body === "object") ? req.body : {};
  const ticket = await addTicket(tenantId, {
    subject: body.subject,
    sender: body.sender,
    body: body.body,
    priority: body.priority,
    due: body.due,
    status: body.status,
  });

  res.status(200).json({ ok: true, ticket });
}

/**
 * /ui/admin autolink (NO admin API).
 * - validates admin key (env ADMIN_KEY)
 * - creates demo tenant (stable) unless ?fresh=1
 * - redirects to /ui/tickets with tenantKey in query
 */
async function adminAutolink(req: Request, res: Response) {
  const admin = (req.query.admin || "").toString();
  const ADMIN_KEY = (process.env.ADMIN_KEY || "").toString();

  if (!ADMIN_KEY) return bad(res, "Admin error", "ADMIN_KEY is missing in env.", "missing_admin_key", 500);
  if (!admin) return bad(res, "Admin error", "Missing ?admin=ADMIN_KEY", "missing_admin", 400);

  // constant time compare to avoid leaks
  if (!constantTimeEq(admin, ADMIN_KEY)) {
    return bad(res, "Admin error", "Bad admin key.", "invalid_admin_key", 401);
  }

  const fresh = (req.query.fresh || "").toString() === "1";
  const tenant = fresh ? await createTenant("Fresh (admin)") : await getOrCreateDemoTenant();

  return res.redirect(302, `/ui/tickets?tenantId=${encodeURIComponent(tenant.tenantId)}&k=${encodeURIComponent(tenant.tenantKey)}`);
}

export function mountUi(app: Express) {
  // Hide /ui root by default (security)
  app.get("/ui", (_req, res) => res.status(404).send("Not found"));

  // Landing (public)
  mountLanding(app);

  // Admin autolink
  app.get("/ui/admin", (req, res) => {
    adminAutolink(req, res).catch((e) => bad(res, "Admin error", "autolink_failed", String(e?.stack || e), 500));
  });

  // Tickets UI
  app.get("/ui/tickets", (req, res) => {
    renderTickets(req, res).catch((e) => bad(res, "Tickets error", "render_failed", String(e?.stack || e), 500));
  });

  // Demo ticket
  app.get("/ui/demo-ticket", (req, res) => {
    demoTicket(req, res).catch((e) => bad(res, "Demo error", "demo_failed", String(e?.stack || e), 500));
  });

  // Export CSV
  app.get("/ui/export.csv", (req, res) => {
    exportCsv(req, res).catch((e) => bad(res, "Export error", "export_failed", String(e?.stack || e), 500));
  });

  // REAL webhook intake
  app.post("/intake/:tenantId", express.json({ limit: "256kb" }), (req, res) => {
    webhookIntake(req, res).catch((e) => res.status(500).json({ ok: false, error: "intake_failed", hint: String(e?.message || e) }));
  });

  // Backward compat (optional): /api/intake/:tenantId
  app.post("/api/intake/:tenantId", express.json({ limit: "256kb" }), (req, res) => {
    webhookIntake(req, res).catch((e) => res.status(500).json({ ok: false, error: "intake_failed", hint: String(e?.message || e) }));
  });
}
TS
echo "✅ wrote src/ui/routes.ts"

# --- [5] Landing (Gumroad-ready quick value + webhook examples) ---
mkdir -p src/ui
cat > src/ui/landing.ts <<'TS'
import type { Express } from "express";

function page(body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Intake-Guardian</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial; background: radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%); color:#e5e7eb; }
  .wrap { max-width: 1180px; margin: 56px auto; padding: 0 18px; }
  .card { border:1px solid rgba(255,255,255,.08); background: rgba(17,24,39,.55); border-radius: 18px; padding: 18px 18px; box-shadow: 0 18px 60px rgba(0,0,0,.35); }
  .h { font-size: 30px; font-weight: 900; margin: 0 0 6px; }
  .muted { color: #9ca3af; font-size: 13px; }
  .grid { display:grid; grid-template-columns: 1.2fr .8fr; gap: 14px; }
  @media (max-width: 980px){ .grid { grid-template-columns: 1fr; } }
  .btn { display:inline-block; padding:10px 14px; border-radius: 12px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.25); color:#e5e7eb; text-decoration:none; font-weight:800; }
  .btn:hover { border-color: rgba(255,255,255,.18); background: rgba(0,0,0,.34); }
  .btn.primary { background: rgba(34,197,94,.16); border-color: rgba(34,197,94,.30); }
  .btn.primary:hover { background: rgba(34,197,94,.22); }
  .kbd { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; font-size: 12px; padding: 3px 8px; border-radius: 10px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.30); color:#e5e7eb; }
  pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
</style>
</head>
<body>
  <div class="wrap">${body}</div>
</body>
</html>`;
}

export function mountLanding(app: Express) {
  app.get("/", (req, res) => {
    const base = `${req.protocol}://${req.get("host")}`;
    const admin = process.env.ADMIN_KEY ? `${base}/ui/admin?admin=${encodeURIComponent(process.env.ADMIN_KEY)}` : `${base}/ui/admin?admin=YOUR_ADMIN_KEY`;
    const demo = `${base}/ui/admin?admin=${process.env.ADMIN_KEY ? encodeURIComponent(process.env.ADMIN_KEY) : "YOUR_ADMIN_KEY"}`;

    const body = `
      <div class="card">
        <div class="h">Intake-Guardian</div>
        <div class="muted">Unified intake inbox + tenant links + CSV proof export — built for agencies & IT support.</div>

        <div class="grid" style="margin-top:14px">
          <div class="card" style="margin:0">
            <div style="font-weight:900; font-size:16px; margin-bottom:8px">What you get</div>
            <ul class="muted" style="margin-top:0; line-height:1.8">
              <li>Client link per tenant (no account UX).</li>
              <li>Tickets inbox (status/priority/due).</li>
              <li>Webhook intake (REAL data) — show value in 60 seconds.</li>
              <li>Export CSV for proof & reporting.</li>
              <li>Demo ticket generator for instant value.</li>
            </ul>
            <div class="muted" style="margin-top:10px">
              Tip: start from <span class="kbd">/ui/admin</span> (admin autolink) then share the client URL.
            </div>
          </div>

          <div class="card" style="margin:0">
            <div style="font-weight:900; font-size:16px; margin-bottom:10px">Try it now</div>
            <div style="display:flex; gap:10px; flex-wrap:wrap; margin-bottom:12px">
              <a class="btn primary" href="${admin}">Open Admin Autolink</a>
              <a class="btn" href="/ui/tickets?tenantId=tenant_demo_local&k=demo">Open Tickets (needs link)</a>
              <a class="btn" href="${demo}">Open Demo Inbox</a>
            </div>

            <div class="muted">Webhook example (after you open admin link and get <span class="kbd">tenantId</span> + <span class="kbd">k</span>):</div>
            <pre>curl -s -X POST "${base}/intake/&lt;tenantId&gt;?k=&lt;tenantKey&gt;" \\
  -H "content-type: application/json" \\
  -d '{"subject":"Website form: pricing","sender":"lead@company.com","body":"Need quote.","priority":"high"}'</pre>

            <div class="muted" style="margin-top:10px">
              Base: <span class="kbd">${base}</span><br/>
              Health: <span class="kbd">${base}/health</span>
            </div>
          </div>
        </div>

        <div class="muted" style="margin-top:14px">System-19 note: never expose ADMIN_KEY in client links.</div>
      </div>
    `;
    res.status(200).type("text/html").send(page(body));
  });
}
TS
echo "✅ wrote src/ui/landing.ts"

# --- [6] Bash-only demo + smoke scripts ---
mkdir -p scripts

cat > scripts/demo-keys.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [ -z "${ADMIN_KEY}" ]; then
  echo "ERR: ADMIN_KEY env is required" >&2
  exit 2
fi

echo "==> Open admin autolink (stable demo tenant)"
echo "${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"
echo

echo "==> Resolve redirect -> final client link"
loc="$(curl -sSI "${BASE_URL}/ui/admin?admin=${ADMIN_KEY}" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')"
if [ -z "${loc}" ]; then
  echo "FAIL: no Location header from /ui/admin" >&2
  exit 1
fi
echo "✅ client link:"
echo "${loc}"
echo

# Parse tenantId + k from loc (POSIX-ish)
tenantId="$(printf "%s" "${loc}" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
k="$(printf "%s" "${loc}" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

if [ -z "${tenantId}" ] || [ -z "${k}" ]; then
  echo "FAIL: could not parse tenantId/k from Location: ${loc}" >&2
  exit 1
fi

echo "==> ✅ Export CSV"
echo "${BASE_URL}/ui/export.csv?tenantId=${tenantId}&k=${k}"
SH2
chmod +x scripts/demo-keys.sh
echo "✅ wrote scripts/demo-keys.sh"

cat > scripts/smoke-ui.sh <<'SH3'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [ -z "${ADMIN_KEY}" ]; then
  echo "ERR: ADMIN_KEY env is required" >&2
  exit 2
fi

echo "==> [0] health"
curl -sS "${BASE_URL}/health" >/dev/null
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
st="$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/ui")"
echo "status=${st}"
if [ "${st}" != "404" ]; then
  echo "FAIL expected 404" >&2
  exit 1
fi

echo "==> [2] /ui/admin redirect (302 expected)"
hdr="$(curl -sSI "${BASE_URL}/ui/admin?admin=${ADMIN_KEY}" || true)"
st="$(printf "%s" "${hdr}" | head -n 1 | awk '{print $2}')"
echo "status=${st}"
if [ "${st}" != "302" ]; then
  echo "FAIL expected 302" >&2
  echo "${hdr}"
  exit 1
fi

loc="$(printf "%s" "${hdr}" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')"
if [ -z "${loc}" ]; then
  echo "FAIL: no Location" >&2
  exit 1
fi

tenantId="$(printf "%s" "${loc}" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
k="$(printf "%s" "${loc}" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

echo "==> [3] follow redirect -> tickets should be 200"
st="$(curl -s -o /dev/null -w "%{http_code}" "${loc}")"
echo "status=${st}"
if [ "${st}" != "200" ]; then
  echo "FAIL expected 200" >&2
  echo "${loc}"
  exit 1
fi

echo "==> [4] send webhook intake (REAL) then confirm tickets still 200"
curl -sS -X POST "${BASE_URL}/intake/${tenantId}?k=${k}" \
  -H "content-type: application/json" \
  -d '{"subject":"Webhook smoke: hello","sender":"smoke@local","body":"ping","priority":"low"}' >/dev/null

st="$(curl -s -o /dev/null -w "%{http_code}" "${loc}")"
echo "status=${st}"
if [ "${st}" != "200" ]; then
  echo "FAIL expected 200 after webhook" >&2
  exit 1
fi

echo "==> [5] export should be 200"
exportUrl="${BASE_URL}/ui/export.csv?tenantId=${tenantId}&k=${k}"
st="$(curl -s -o /dev/null -w "%{http_code}" "${exportUrl}")"
echo "status=${st}"
if [ "${st}" != "200" ]; then
  echo "FAIL expected 200 on export: ${exportUrl}" >&2
  exit 1
fi

echo "✅ smoke ui ok"
echo "${loc}"
echo "${exportUrl}"
SH3
chmod +x scripts/smoke-ui.sh
echo "✅ wrote scripts/smoke-ui.sh"

# --- [7] Typecheck ---
echo "==> [7] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase21 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
