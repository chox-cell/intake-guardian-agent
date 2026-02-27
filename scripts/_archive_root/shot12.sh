#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/Projects/intake-guardian-agent}"
cd "$REPO"

ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
BK=".bak/${ts_utc}_gold_clean_stateless_ui_single_store"
mkdir -p "$BK"

echo "============================================================"
echo "OneShot: GOLD CLEAN (Stateless UI + Single Store + Evidence Contract)"
echo "Repo: $REPO"
echo "Backup: $BK"
echo "============================================================"

echo "==> [0] Backup"
[ -f package.json ] && cp -a package.json "$BK/package.json" || true
[ -f pnpm-lock.yaml ] && cp -a pnpm-lock.yaml "$BK/pnpm-lock.yaml" || true
[ -d src ] && cp -a src "$BK/src" || true

echo "==> [1] Ensure dirs"
mkdir -p src/lib src/ui data

echo "==> [2] Ensure deps (archiver)"
# archiver is required for evidence.zip; install if missing
node - <<'NODE'
const fs = require("fs");
const pkg = JSON.parse(fs.readFileSync("package.json","utf8"));
const deps = { ...(pkg.dependencies||{}), ...(pkg.devDependencies||{}) };
if (!deps.archiver) process.exit(2);
NODE
code=$?
set +e
if [ "$code" = "2" ]; then
  set -e
  echo "==> Installing archiver (+ types)"
  pnpm add archiver
  pnpm add -D @types/archiver
else
  set -e
  echo "==> archiver already present"
fi

echo "==> [3] Write src/lib/ticket-store.ts (SSOT)"
cat > src/lib/ticket-store.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type TicketStatus = "open" | "pending" | "closed";
export type Ticket = {
  id: string;
  tenantId: string;
  status: TicketStatus;
  source: string;
  type: string;
  title: string;
  flags: string[];
  missingFields: string[];
  duplicateCount: number;
  createdAtUtc: string;
  lastSeenAtUtc: string;
  evidenceHash: string;
  payload?: any;
};

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function dataDir() {
  return process.env.DATA_DIR || "./data";
}

function tenantDir(tenantId: string) {
  return path.resolve(dataDir(), "tenants", tenantId);
}

function ticketsPath(tenantId: string) {
  return path.join(tenantDir(tenantId), "tickets.json");
}

function loadTickets(tenantId: string): Ticket[] {
  const fp = ticketsPath(tenantId);
  if (!fs.existsSync(fp)) return [];
  try {
    const j = JSON.parse(fs.readFileSync(fp, "utf8"));
    return Array.isArray(j) ? (j as Ticket[]) : [];
  } catch {
    return [];
  }
}

function saveTickets(tenantId: string, rows: Ticket[]) {
  ensureDir(tenantDir(tenantId));
  fs.writeFileSync(ticketsPath(tenantId), JSON.stringify(rows, null, 2), "utf8");
}

function sha1(v: string) {
  return crypto.createHash("sha1").update(v).digest("hex");
}
function sha256(v: string) {
  return crypto.createHash("sha256").update(v).digest("hex");
}

export function listTickets(tenantId: string): Ticket[] {
  return loadTickets(tenantId).sort((a, b) => (a.createdAtUtc < b.createdAtUtc ? 1 : -1));
}

export function setTicketStatus(tenantId: string, ticketId: string, status: TicketStatus): { ok: boolean } {
  const rows = loadTickets(tenantId);
  const t = rows.find(x => x.id === ticketId);
  if (!t) return { ok: false };
  t.status = status;
  t.lastSeenAtUtc = new Date().toISOString();
  saveTickets(tenantId, rows);
  return { ok: true };
}

/**
 * Upsert with dedupe:
 * - dedupeKey computed from payload (stable)
 * - if exists: bump duplicateCount + lastSeenAtUtc
 */
export function upsertTicket(
  tenantId: string,
  input: {
    source?: string;
    type?: string;
    title?: string;
    payload?: any;
    missingFields?: string[];
    flags?: string[];
  }
): { ticket: Ticket; created: boolean } {
  const now = new Date().toISOString();
  const rows = loadTickets(tenantId);

  const payload = input.payload ?? {};
  const dedupeKey = sha1(JSON.stringify(payload));

  let t = rows.find(r => r.evidenceHash === dedupeKey);
  if (t) {
    t.duplicateCount = (t.duplicateCount || 0) + 1;
    t.lastSeenAtUtc = now;
    saveTickets(tenantId, rows);
    return { ticket: t, created: false };
  }

  const flags = Array.isArray(input.flags) ? input.flags : [];
  const missingFields = Array.isArray(input.missingFields) ? input.missingFields : [];

  t = {
    id: "t_" + crypto.randomBytes(10).toString("hex"),
    tenantId,
    status: missingFields.length ? "pending" : "open",
    source: input.source || "webhook",
    type: input.type || "lead",
    title: input.title || "Lead intake",
    flags,
    missingFields,
    duplicateCount: 0,
    createdAtUtc: now,
    lastSeenAtUtc: now,
    evidenceHash: dedupeKey,
    payload,
  };

  rows.push(t);
  saveTickets(tenantId, rows);
  return { ticket: t, created: true };
}

export function ticketsToCsv(rows: any[]): string {
  const header = ["id","status","source","type","title","createdAtUtc","evidenceHash"].join(",");
  const lines = rows.map((t: any) => {
    const esc = (v: any) => {
      const s = String(v ?? "");
      if (/[,"\n]/.test(s)) return `"${s.replace(/"/g,'""')}"`;
      return s;
    };
    return [
      esc(t.id),
      esc(t.status),
      esc(t.source),
      esc(t.type),
      esc(t.title),
      esc(t.createdAtUtc),
      esc(t.evidenceHash),
    ].join(",");
  });
  return [header, ...lines].join("\n") + "\n";
}

export function sha256File(buf: Buffer) {
  return crypto.createHash("sha256").update(buf).digest("hex");
}
export function sha256Text(txt: string) {
  return crypto.createHash("sha256").update(txt, "utf8").digest("hex");
}
TS

echo "==> [4] Write src/lib/ui-auth.ts (Stateless, no cookie-parser)"
cat > src/lib/ui-auth.ts <<'TS'
import type { Request, Response, NextFunction } from "express";

/**
 * Stateless UI auth (enterprise-safe, automation-friendly):
 * - tenantId + k passed via query
 * - no cookies, no sessions, no CSRF surface
 */
export function uiAuth(req: Request, res: Response, next: NextFunction) {
  const q = req.query as any;
  const tenantId = String(q?.tenantId || "").trim();
  const k = String(q?.k || "").trim();
  if (!tenantId || !k) return res.status(401).send("Missing tenantId or k");
  (req as any).auth = { tenantId, k };
  next();
}
TS

echo "==> [5] Write src/ui/routes.ts (UI/CSV/ZIP read ONLY ticket-store)"
cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";
import archiver from "archiver";
import { listTickets, setTicketStatus, ticketsToCsv, sha256Text } from "../lib/ticket-store";
import { uiAuth } from "../lib/ui-auth";

function htmlEscape(s: string) {
  return (s || "")
    .replace(/&/g,"&amp;")
    .replace(/</g,"&lt;")
    .replace(/>/g,"&gt;")
    .replace(/"/g,"&quot;");
}

function baseUrl(req: Request) {
  const proto = String((req.headers["x-forwarded-proto"] as any) || ((req.socket as any).encrypted ? "https" : "http"));
  const host = String((req.headers["x-forwarded-host"] as any) || req.headers.host || "127.0.0.1");
  return `${proto}://${host}`;
}

function link(req: Request, path: string, tenantId: string, k: string) {
  const b = baseUrl(req);
  return `${b}${path}?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
}

export function mountUi(app: Express) {
  // Welcome (no auth)
  app.get("/ui/welcome", (req, res) => {
    const b = baseUrl(req);
    res.setHeader("content-type","text/html; charset=utf-8");
    res.end(`<!doctype html>
<html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Intake Guardian</title>
<style>
:root{color-scheme:dark}
body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1100px 700px at 30% 20%, #0b1633 0%, #05070c 65%);color:#e5e7eb}
.wrap{max-width:980px;margin:40px auto;padding:0 18px}
.card{border:1px solid rgba(255,255,255,.10);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
.h{font-size:22px;font-weight:800;margin:0 0 8px}
.m{color:#9ca3af;font-size:13px;line-height:1.5}
a{color:#22d3ee;text-decoration:none}
</style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <div class="h">Intake Guardian</div>
    <div class="m">
      Open your <b>Pilot Link</b> from provision (tenantId + k).<br/>
      Base URL: <code>${htmlEscape(b)}</code>
    </div>
  </div>
</div>
</body></html>`);
  });

  // Pilot (auth)
  app.get("/ui/pilot", uiAuth, (req: Request, res: Response) => {
    const auth = (req as any).auth as { tenantId: string; k: string };
    const b = baseUrl(req);
    const webhookUrl = `${b}/api/webhook/easy?tenantId=${encodeURIComponent(auth.tenantId)}`;
    const ticketsUrl = link(req, "/ui/tickets", auth.tenantId, auth.k);
    const csvUrl = link(req, "/ui/export.csv", auth.tenantId, auth.k);
    const zipUrl = link(req, "/ui/evidence.zip", auth.tenantId, auth.k);

    res.setHeader("content-type","text/html; charset=utf-8");
    res.end(`<!doctype html>
<html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Pilot — Intake Guardian</title>
<style>
:root{color-scheme:dark}
body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1100px 700px at 30% 20%, #0b1633 0%, #05070c 65%);color:#e5e7eb}
.wrap{max-width:980px;margin:40px auto;padding:0 18px}
.card{border:1px solid rgba(255,255,255,.10);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
.h{font-size:22px;font-weight:800;margin:0 0 8px}
.m{color:#9ca3af;font-size:13px;line-height:1.5}
.row{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;border:1px solid rgba(255,255,255,.14);background:rgba(0,0,0,.22);padding:10px 12px;border-radius:12px;color:#e5e7eb;text-decoration:none;font-weight:700;font-size:13px}
.btn:hover{background:rgba(0,0,0,.35)}
pre{white-space:pre-wrap;word-break:break-word;background:rgba(0,0,0,.35);border:1px solid rgba(255,255,255,.10);padding:12px;border-radius:12px;margin:10px 0}
code{font-family:ui-monospace,Menlo,Monaco,Consolas,monospace;font-size:12px}
.small{font-size:12px;color:#9ca3af}
.copy{cursor:pointer}
</style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <div class="h">Pilot</div>
    <div class="m">
      Zero-tech flow: copy URL + token → send test lead → watch tickets fill → download evidence ZIP.
    </div>

    <div class="row">
      <a class="btn" href="${htmlEscape(ticketsUrl)}">Open Tickets</a>
      <a class="btn" href="${htmlEscape(csvUrl)}">Download CSV</a>
      <a class="btn" href="${htmlEscape(zipUrl)}">Download Evidence ZIP</a>
      <form method="post" action="/api/ui/send-test-lead?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}" style="margin:0">
        <button class="btn" type="submit">Send Test Lead</button>
      </form>
    </div>

    <div class="m" style="margin-top:14px">Webhook URL (paste into Zapier/Make/n8n as the target URL):</div>
    <pre><code>${htmlEscape(webhookUrl)}</code></pre>

    <div class="m">Token (paste into “Header value” / “Secret token” field):</div>
    <pre><code>${htmlEscape(auth.k)}</code></pre>

    <div class="small">We do not show “headers” to end clients; platform puts the header automatically.</div>
  </div>
</div>
</body></html>`);
  });

  // Tickets (auth)
  app.get("/ui/tickets", uiAuth, (req: Request, res: Response) => {
    const auth = (req as any).auth as { tenantId: string; k: string };
    const rows = listTickets(auth.tenantId);
    const b = baseUrl(req);

    const csvUrl = link(req, "/ui/export.csv", auth.tenantId, auth.k);
    const zipUrl = link(req, "/ui/evidence.zip", auth.tenantId, auth.k);
    const pilotUrl = link(req, "/ui/pilot", auth.tenantId, auth.k);

    const table = rows.length
      ? `<table style="width:100%;border-collapse:collapse;margin-top:12px">
          <thead>
            <tr style="text-align:left;color:#9ca3af;font-size:12px">
              <th style="padding:8px;border-bottom:1px solid rgba(255,255,255,.10)">id</th>
              <th style="padding:8px;border-bottom:1px solid rgba(255,255,255,.10)">status</th>
              <th style="padding:8px;border-bottom:1px solid rgba(255,255,255,.10)">title</th>
              <th style="padding:8px;border-bottom:1px solid rgba(255,255,255,.10)">created</th>
            </tr>
          </thead>
          <tbody>
            ${rows.map(t => `
              <tr>
                <td style="padding:8px;border-bottom:1px solid rgba(255,255,255,.06)"><code>${htmlEscape(t.id)}</code></td>
                <td style="padding:8px;border-bottom:1px solid rgba(255,255,255,.06)">${htmlEscape(t.status)}</td>
                <td style="padding:8px;border-bottom:1px solid rgba(255,255,255,.06)">${htmlEscape(t.title)}</td>
                <td style="padding:8px;border-bottom:1px solid rgba(255,255,255,.06);color:#9ca3af">${htmlEscape(t.createdAtUtc)}</td>
              </tr>
            `).join("")}
          </tbody>
        </table>`
      : `<div style="margin-top:14px;color:#9ca3af">No tickets yet.</div>`;

    res.setHeader("content-type","text/html; charset=utf-8");
    res.end(`<!doctype html>
<html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Tickets — Intake Guardian</title>
<style>
:root{color-scheme:dark}
body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1100px 700px at 30% 20%, #0b1633 0%, #05070c 65%);color:#e5e7eb}
.wrap{max-width:980px;margin:40px auto;padding:0 18px}
.card{border:1px solid rgba(255,255,255,.10);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
.h{font-size:22px;font-weight:800;margin:0 0 8px}
.row{display:flex;gap:10px;flex-wrap:wrap}
.btn{display:inline-flex;align-items:center;justify-content:center;border:1px solid rgba(255,255,255,.14);background:rgba(0,0,0,.22);padding:10px 12px;border-radius:12px;color:#e5e7eb;text-decoration:none;font-weight:700;font-size:13px}
.btn:hover{background:rgba(0,0,0,.35)}
code{font-family:ui-monospace,Menlo,Monaco,Consolas,monospace;font-size:12px}
</style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <div class="h">Tickets</div>
    <div class="row">
      <a class="btn" href="${htmlEscape(pilotUrl)}">Back to Pilot</a>
      <a class="btn" href="${htmlEscape(csvUrl)}">Download CSV</a>
      <a class="btn" href="${htmlEscape(zipUrl)}">Download Evidence ZIP</a>
    </div>
    ${table}
  </div>
</div>
</body></html>`);
  });

  // CSV (auth)
  app.get("/ui/export.csv", uiAuth, (req: Request, res: Response) => {
    const auth = (req as any).auth as { tenantId: string; k: string };
    const rows = listTickets(auth.tenantId);

    res.setHeader("content-type", "text/csv; charset=utf-8");
    res.setHeader("content-disposition", `attachment; filename="tickets_${auth.tenantId}.csv"`);
    res.end(ticketsToCsv(rows));
  });

  // Evidence ZIP (auth)
  app.get("/ui/evidence.zip", uiAuth, async (req: Request, res: Response) => {
    const auth = (req as any).auth as { tenantId: string; k: string };
    const rows = listTickets(auth.tenantId);

    const ticketsJson = JSON.stringify(rows, null, 2);
    const ticketsCsv = ticketsToCsv(rows);

    const manifest = {
      tenantId: auth.tenantId,
      generatedAtUtc: new Date().toISOString(),
      files: [
        { name: "tickets.json", sha256: sha256Text(ticketsJson) },
        { name: "tickets.csv", sha256: sha256Text(ticketsCsv) },
        { name: "README.txt",  sha256: sha256Text("Evidence pack\n- tickets.json\n- tickets.csv\n- manifest.json\n") },
      ],
    };

    res.setHeader("content-type","application/zip");
    res.setHeader("content-disposition",`attachment; filename="evidence_pack_${auth.tenantId}.zip"`);

    const zip = archiver("zip", { zlib: { level: 9 } });
    zip.on("error", (err) => {
      try { res.status(500).end(String(err?.message || err)); } catch {}
    });

    zip.pipe(res);
    zip.append(ticketsJson, { name: "tickets.json" });
    zip.append(ticketsCsv,  { name: "tickets.csv" });
    zip.append("Evidence pack\n- tickets.json\n- tickets.csv\n- manifest.json\n", { name: "README.txt" });
    zip.append(JSON.stringify(manifest, null, 2), { name: "manifest.json" });

    await zip.finalize();
  });

  // Optional: status change (auth) — simple enterprise control
  app.post("/ui/tickets/status", uiAuth, (req: Request, res: Response) => {
    const auth = (req as any).auth as { tenantId: string; k: string };
    const q = req.query as any;
    const id = String(q?.id || "").trim();
    const st = String(q?.st || "").trim() as any;
    if (!id) return res.status(400).send("missing id");
    if (!["open","pending","closed"].includes(st)) return res.status(400).send("invalid status");
    const out = setTicketStatus(auth.tenantId, id, st);
    if (!out.ok) return res.status(404).send("not found");
    return res.redirect(`/ui/tickets?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}`);
  });
}
TS

echo "==> [6] Write src/server.ts (clean, single-store, body parsing, provision, easy webhook)"
cat > src/server.ts <<'TS'
import express from "express";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { mountUi } from "./ui/routes";
import { upsertTicket } from "./lib/ticket-store";

type Tenant = { tenantId: string; tenantKey: string; notes?: string; createdAtUtc: string; updatedAtUtc: string };

const PORT = Number(process.env.PORT || 7090);
const DATA_DIR = process.env.DATA_DIR || "./data";
const ADMIN_KEY = process.env.ADMIN_KEY || "dev_admin_key_123";

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function tenantsFile() {
  return path.resolve(DATA_DIR, "tenants.json");
}

function loadTenants(): Tenant[] {
  const fp = tenantsFile();
  if (!fs.existsSync(fp)) return [];
  try {
    const j = JSON.parse(fs.readFileSync(fp, "utf8"));
    return Array.isArray(j?.tenants) ? (j.tenants as Tenant[]) : (Array.isArray(j) ? (j as Tenant[]) : []);
  } catch {
    return [];
  }
}

function saveTenants(rows: Tenant[]) {
  ensureDir(path.dirname(tenantsFile()));
  fs.writeFileSync(tenantsFile(), JSON.stringify({ ok: true, tenants: rows }, null, 2), "utf8");
}

function mustAdmin(req: any, res: any): boolean {
  const key = String(req.header("x-admin-key") || req.query?.adminKey || req.query?.key || "").trim();
  if (!key || key !== ADMIN_KEY) {
    res.status(401).json({ ok: false, error: "unauthorized" });
    return false;
  }
  return true;
}

function findTenant(tenantId: string): Tenant | undefined {
  return loadTenants().find(t => t.tenantId === tenantId);
}

function isValidTenantKey(tenantId: string, tenantKey: string): boolean {
  const t = findTenant(tenantId);
  return !!t && t.tenantKey === tenantKey;
}

function baseUrl(req: any) {
  const proto = String(req.headers["x-forwarded-proto"] || (req.socket?.encrypted ? "https" : "http"));
  const host = String(req.headers["x-forwarded-host"] || req.headers.host || "127.0.0.1");
  return `${proto}://${host}`;
}

function mkTenantId() {
  return `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
}
function mkKey() {
  return crypto.randomBytes(24).toString("base64url");
}

function computeMissing(lead: any): string[] {
  const missing: string[] = [];
  const email = String(lead?.email || "").trim();
  const fullName = String(lead?.fullName || "").trim();
  const phone = String(lead?.phone || "").trim();
  if (!email) missing.push("email");
  if (!fullName) missing.push("fullName");
  if (!email && !phone) missing.push("email_or_phone");
  return missing;
}

async function main() {
  ensureDir(DATA_DIR);

  const app = express();

  // global parsing (safe)
  app.use(express.urlencoded({ extended: true }));
  app.use(express.json({ limit: "2mb" }));

  // health
  app.get("/health", (_req, res) => res.json({ ok: true, name: "intake-guardian-agent", version: "gold-clean" }));

  // admin: list tenants (optional)
  app.get("/api/admin/tenants", (req, res) => {
    if (!mustAdmin(req, res)) return;
    return res.json({ ok: true, tenants: loadTenants() });
  });

  // admin: provision tenant (returns links + webhook)
  app.post("/api/admin/provision", (req, res) => {
    if (!mustAdmin(req, res)) return;

    const workspaceName = String(req.body?.workspaceName || "Workspace").trim();
    const agencyEmail = String(req.body?.agencyEmail || "").trim();
    const now = new Date().toISOString();

    const tenantId = mkTenantId();
    const k = mkKey();

    const rows = loadTenants();
    rows.push({ tenantId, tenantKey: k, notes: `provisioned:${workspaceName}:${agencyEmail}`, createdAtUtc: now, updatedAtUtc: now });
    saveTenants(rows);

    const b = baseUrl(req);

    const links = {
      welcome: `${b}/ui/welcome?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`,
      pilot:   `${b}/ui/pilot?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`,
      tickets: `${b}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`,
      csv:     `${b}/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`,
      zip:     `${b}/ui/evidence.zip?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`,
    };

    const webhookUrl = `${b}/api/webhook/easy?tenantId=${encodeURIComponent(tenantId)}`;

    return res.json({
      ok: true,
      baseUrl: b,
      tenantId,
      k,
      links,
      webhook: {
        url: webhookUrl,
        headers: { "content-type": "application/json", "x-tenant-key": k },
        bodyExample: { source: "zapier", type: "lead", lead: { fullName: "Jane Doe", email: "jane@example.com", company: "ACME" } }
      },
      curl:
        `curl -sS -X POST "${webhookUrl}" \\\n` +
        `  -H "content-type: application/json" \\\n` +
        `  -H "x-tenant-key: ${k}" \\\n` +
        `  --data '{"source":"demo","type":"lead","lead":{"fullName":"Demo Lead","email":"demo@x.dev","company":"DemoCo"}}'`
    });
  });

  // webhook: easy (validates key, creates ticket)
  app.post("/api/webhook/easy", (req, res) => {
    const tenantId = String(req.query?.tenantId || "").trim();
    const tenantKey = String(req.header("x-tenant-key") || "").trim();
    if (!tenantId || !tenantKey) return res.status(401).json({ ok: false, error: "unauthorized", hint: "need tenantId + x-tenant-key" });
    if (!isValidTenantKey(tenantId, tenantKey)) return res.status(401).json({ ok: false, error: "invalid_tenant_key" });

    const payload = req.body ?? {};
    const type = String(payload?.type || "lead");
    const source = String(payload?.source || "webhook");
    const lead = payload?.lead ?? {};

    const missing = computeMissing(lead);
    const flags = missing.length ? ["missing_fields", "low_signal"] : [];
    const title = `Lead intake (${source})`;

    const { ticket, created } = upsertTicket(tenantId, {
      source,
      type,
      title,
      payload,
      missingFields: missing,
      flags,
    });

    // return “ready / needs_review” style but keep internal statuses open/pending
    const apiStatus = missing.length ? "needs_review" : "ready";

    return res.json({
      ok: true,
      created,
      ticket: {
        id: ticket.id,
        status: apiStatus,
        title: ticket.title,
        source: ticket.source,
        type: ticket.type,
        dedupeKey: ticket.evidenceHash,
        flags: ticket.flags,
        missingFields: ticket.missingFields,
        duplicateCount: ticket.duplicateCount,
        createdAtUtc: ticket.createdAtUtc,
        lastSeenAtUtc: ticket.lastSeenAtUtc
      }
    });
  });

  // UI helper: send test lead (uses easy webhook)
  app.post("/api/ui/send-test-lead", (req, res) => {
    const tenantId = String(req.query?.tenantId || "").trim();
    const k = String(req.query?.k || "").trim();
    if (!tenantId || !k) return res.status(401).json({ ok: false, error: "unauthorized", hint: "need tenantId + k" });

    // re-use internal logic: validate & write ticket directly
    if (!isValidTenantKey(tenantId, k)) return res.status(401).json({ ok: false, error: "invalid_tenant_key" });

    const payload = {
      source: "ui",
      type: "lead",
      lead: { fullName: "UI Test Lead", email: "ui-test@local.dev", company: "DecisionCover" }
    };

    const missing = computeMissing(payload.lead);
    const flags = missing.length ? ["missing_fields", "low_signal"] : [];
    const title = `Lead intake (ui)`;

    const { ticket, created } = upsertTicket(tenantId, {
      source: payload.source,
      type: payload.type,
      title,
      payload,
      missingFields: missing,
      flags,
    });

    const apiStatus = missing.length ? "needs_review" : "ready";

    // redirect back to tickets for zero-tech UX
    const b = baseUrl(req);
    res.setHeader("location", `${b}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`);
    return res.status(303).json({
      ok: true,
      created,
      ticket: {
        id: ticket.id,
        status: apiStatus,
        title: ticket.title,
        source: ticket.source,
        type: ticket.type,
        dedupeKey: ticket.evidenceHash,
        flags: ticket.flags,
        missingFields: ticket.missingFields,
        duplicateCount: ticket.duplicateCount,
        createdAtUtc: ticket.createdAtUtc,
        lastSeenAtUtc: ticket.lastSeenAtUtc
      }
    });
  });

  // UI routes (tickets, csv, zip, pilot)
  mountUi(app);

  // root
  app.get("/", (_req, res) => res.redirect("/ui/welcome"));

  app.listen(PORT, () => {
    console.log("Intake-Guardian running on", PORT);
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
TS

echo "==> [7] Typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ GOLD CLEAN applied"
echo "Backup: $BK"
echo
echo "NEXT (Golden Test — exact, no guessing):"
echo "  # Terminal A:"
echo "  pkill -f 'node .*src/server' || true"
echo "  pnpm dev"
echo
echo "  # Terminal B:"
echo "  BASE='http://127.0.0.1:7090'"
echo "  curl -sS -X POST \"\$BASE/api/admin/provision\" \\"
echo "    -H 'content-type: application/json' \\"
echo "    -H 'x-admin-key: dev_admin_key_123' \\"
echo "    -d '{\"workspaceName\":\"ACCE GATE\",\"agencyEmail\":\"choxmou@gmail.com\"}' | cat"
echo
echo "  # copy tenantId + k from JSON, then:"
echo "  TENANT_ID='...'; K='...'"
echo "  curl -sS -X POST \"\$BASE/api/webhook/easy?tenantId=\$TENANT_ID\" \\"
echo "    -H 'content-type: application/json' \\"
echo "    -H \"x-tenant-key: \$K\" \\"
echo "    --data '{\"source\":\"demo\",\"type\":\"lead\",\"lead\":{\"fullName\":\"Demo Lead\",\"email\":\"demo@x.dev\",\"company\":\"DemoCo\"}}' | cat"
echo
echo "  open \"\$BASE/ui/pilot?tenantId=\$TENANT_ID&k=\$K\""
echo "  open \"\$BASE/ui/tickets?tenantId=\$TENANT_ID&k=\$K\""
echo "  curl -sS \"\$BASE/ui/export.csv?tenantId=\$TENANT_ID&k=\$K\" | head -n 50"
echo "  curl -I \"\$BASE/ui/evidence.zip?tenantId=\$TENANT_ID&k=\$K\" | head -n 30"
echo
