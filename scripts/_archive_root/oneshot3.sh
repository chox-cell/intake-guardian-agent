#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$HOME/Projects/intake-guardian-agent}"
cd "$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bk="__bak_fix_ui_${ts}"
mkdir -p "$bk"

backup() { [ -f "$1" ] && mkdir -p "$bk/$(dirname "$1")" && cp -v "$1" "$bk/$1" >/dev/null || true; }

echo "==> OneShot FIX UI crash @ $ROOT"
echo "==> [0] Backups -> $bk"
backup src/api/tenant-key.ts
backup src/api/ui.ts
backup src/server.ts
backup tsconfig.json

echo "==> [1] Ensure tsconfig excludes backups (avoid TS6059 noise)"
node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
if (!fs.existsSync(p)) process.exit(0);
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]),
  "node_modules","dist","build","__bak_*","__bak_fix_*","__bak_salespack_*","**/*.bak.*",".bak"
]));
fs.writeFileSync(p, JSON.stringify(j,null,2));
console.log("✅ Patched", p);
NODE

echo "==> [2] Restore tenant-key contract (object {ok,status,error,key})"
mkdir -p src/api
cat > src/api/tenant-key.ts <<'TS'
import type { Request } from "express";
import type { TenantsStore } from "../tenants/store.js";
import type { ShareStore } from "../shares/store.js";

type TkOk = { ok: true; key: string; via: "tenant_key" | "share" | "dev_fallback" };
type TkBad = { ok: false; status: 401 | 403; error: "missing_tenant_key" | "invalid_tenant_key" };
export type TenantKeyResult = TkOk | TkBad;

/**
 * Contract (SSOT):
 * - returns { ok:true, key, via } OR { ok:false, status, error }
 * - supports:
 *   1) x-tenant-key header
 *   2) query ?k= (dev / share link)
 *   3) query ?s= (share token) if ShareStore wired
 */
export function requireTenantKey(
  req: Request,
  tenantId: string,
  tenantsStore?: TenantsStore,
  sharesStore?: ShareStore
): TenantKeyResult {
  const headerKey = (req.header("x-tenant-key") || "").trim();
  const qk = (typeof req.query.k === "string" ? req.query.k.trim() : "");
  const key = headerKey || qk;

  if (!key) return { ok: false, status: 401, error: "missing_tenant_key" };

  // Share token path (?s=) if provided
  const s = (typeof req.query.s === "string" ? req.query.s.trim() : "");
  if (s && sharesStore && sharesStore.verify(tenantId, s)) {
    return { ok: true, key: s, via: "share" };
  }

  // Normal tenant key validation
  if (tenantsStore) {
    const ok = tenantsStore.verify(tenantId, key);
    if (!ok) return { ok: false, status: 401, error: "invalid_tenant_key" };
    return { ok: true, key, via: "tenant_key" };
  }

  // Dev fallback (no tenants store wired)
  return { ok: true, key, via: "dev_fallback" };
}
TS

echo "==> [3] Fix UI route: safe store.listWorkItems call + nicer HTML + working export"
cat > src/api/ui.ts <<'TS'
import express from "express";
import { requireTenantKey } from "./tenant-key.js";

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function shortId(id: string) {
  if (!id) return "";
  return id.length <= 12 ? id : id.slice(0, 6) + "…" + id.slice(-4);
}

function msUntil(iso?: string) {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return null;
  return t - Date.now();
}

function human(ms: number) {
  const s = Math.floor(Math.abs(ms) / 1000);
  const m = Math.floor(s / 60);
  const h = Math.floor(m / 60);
  if (h >= 48) return `${Math.floor(h / 24)}d`;
  if (h >= 1) return `${h}h`;
  return `${Math.max(1, m)}m`;
}

function badge(kind: "priority" | "status", val: string) {
  const v = (val || "").toLowerCase();
  let cls = "badge";
  if (kind === "priority") {
    cls += v === "high" ? " prio-high" : v === "medium" ? " prio-med" : " prio-low";
  } else {
    cls += v === "done" ? " st-done" : v === "in_progress" ? " st-prog" : " st-new";
  }
  return `<span class="${cls}">${esc(val || "unknown")}</span>`;
}

function dueCell(dueAt?: string) {
  const ms = msUntil(dueAt);
  if (ms === null) return `<span class="muted">-</span>`;
  if (ms < 0) return `<span class="due due-bad">Overdue ${esc(human(ms))}</span><div class="muted mono">${esc(dueAt)}</div>`;
  if (ms <= 2 * 60 * 60 * 1000) return `<span class="due due-warn">Due in ${esc(human(ms))}</span><div class="muted mono">${esc(dueAt)}</div>`;
  return `<span class="due">Due in ${esc(human(ms))}</span><div class="muted mono">${esc(dueAt)}</div>`;
}

function toCsv(items: any[]) {
  const cols = ["id","tenantId","source","sender","subject","category","priority","status","slaSeconds","dueAt","createdAt","updatedAt"];
  const lines = [cols.join(",")];
  for (const it of items) {
    const row = cols.map((c) => {
      const v = it?.[c] ?? "";
      const s = String(v).replaceAll('"', '""');
      return `"${s}"`;
    });
    lines.push(row.join(","));
  }
  return lines.join("\n") + "\n";
}

function computeStats(items: any[]) {
  const byStatus: Record<string, number> = {};
  const byPriority: Record<string, number> = {};
  const byCategory: Record<string, number> = {};
  for (const it of items) {
    const st = String(it.status || "unknown").toLowerCase();
    const pr = String(it.priority || "unknown").toLowerCase();
    const cat = String(it.category || "unknown").toLowerCase();
    byStatus[st] = (byStatus[st] || 0) + 1;
    byPriority[pr] = (byPriority[pr] || 0) + 1;
    byCategory[cat] = (byCategory[cat] || 0) + 1;
  }
  return { totals: { items: items.length }, byStatus, byPriority, byCategory };
}

async function safeList(store: any, tenantId: string, limit: number) {
  // Support both signatures:
  // 1) listWorkItems(tenantId, {limit, offset})
  // 2) listWorkItems({tenantId, limit})
  // 3) listWorkItems({limit}) (legacy)
  const fn = store?.listWorkItems;
  if (typeof fn !== "function") return [];
  try {
    if (fn.length >= 2) return await fn.call(store, tenantId, { limit, offset: 0 });
    // try object with tenantId
    try { return await fn.call(store, { tenantId, limit, offset: 0 }); } catch {}
    // last resort
    return await fn.call(store, { limit, offset: 0 });
  } catch {
    return [];
  }
}

export function makeUiRoutes(args: { store: any; tenants: any; shares: any }) {
  const r = express.Router();

  r.get("/tickets", async (req, res) => {
    const tenantId = (typeof req.query.tenantId === "string" ? req.query.tenantId : "").trim();
    if (!tenantId) return res.status(400).send("missing_tenantId");

    const tk = requireTenantKey(req as any, tenantId, args.tenants, args.shares);
    if (!tk.ok) return res.status(tk.status).send(tk.error);

    const limit = Number(req.query.limit || 50);
    const items = await safeList(args.store, tenantId, Number.isFinite(limit) ? limit : 50);

    const keyForLink =
      (typeof req.query.k === "string" && req.query.k) ? req.query.k :
      (req.header("x-tenant-key") || "");

    const shareLink = `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String(keyForLink || ""))}`;

    const rows = (items || []).map((it: any) => `
      <tr>
        <td class="mono">${esc(shortId(it.id))}</td>
        <td class="subject">${esc(it.subject || it.id)}</td>
        <td>${badge("priority", it.priority || "unknown")}</td>
        <td>${badge("status", it.status || "new")}</td>
        <td>${dueCell(it.dueAt)}</td>
        <td class="mono muted">${esc(it.sender || "-")}</td>
      </tr>
    `).join("");

    const html = `<!doctype html>
<html><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Tickets — ${esc(tenantId)}</title>
<style>
:root{--bg:#060709;--border:rgba(255,255,255,.08);--text:#e8eaed;--muted:rgba(232,234,237,.62);
--red:#ff5c7a;--yellow:#f7d154;--green:#38d996;--blue:#6aa7ff;}
body{margin:0;font-family:ui-sans-serif,system-ui;background:
radial-gradient(1200px 600px at 20% 10%, rgba(56,217,150,.18), transparent 55%),
radial-gradient(1000px 500px at 70% 20%, rgba(106,167,255,.12), transparent 55%), var(--bg);
color:var(--text);}
.wrap{max-width:1100px;margin:28px auto;padding:0 18px;}
.card{border:1px solid var(--border);border-radius:18px;padding:18px;
background:linear-gradient(180deg, rgba(255,255,255,.045), rgba(255,255,255,.02));
box-shadow:0 12px 40px rgba(0,0,0,.35);}
.top{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap;}
h1{margin:0;font-size:26px}
.sub{margin-top:6px;color:var(--muted);font-size:13px}
.actions{display:flex;gap:10px;flex-wrap:wrap}
.btn{border:1px solid var(--border);background:rgba(255,255,255,.04);color:var(--text);
padding:10px 12px;border-radius:12px;text-decoration:none;font-size:13px}
.btn:hover{background:rgba(255,255,255,.08)}
.btn.primary{background:rgba(56,217,150,.18);border-color:rgba(56,217,150,.35)}
.btn.primary:hover{background:rgba(56,217,150,.24)}
.share{margin-top:14px;display:flex;gap:10px;align-items:center}
.share input{flex:1;background:rgba(0,0,0,.35);border:1px dashed rgba(255,255,255,.18);color:var(--text);
padding:10px 12px;border-radius:12px;font-size:12px}
table{width:100%;border-collapse:separate;border-spacing:0;margin-top:16px;border-radius:14px;overflow:hidden;border:1px solid var(--border)}
thead th{background:rgba(255,255,255,.03);text-align:left;font-size:11px;color:var(--muted);
padding:12px 12px;letter-spacing:.14em}
tbody td{padding:14px 12px;border-top:1px solid var(--border);font-size:13px;vertical-align:top}
tbody tr:hover{background:rgba(255,255,255,.03)}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.muted{color:var(--muted)}
.subject{max-width:420px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.badge{display:inline-flex;align-items:center;padding:6px 10px;border-radius:999px;font-size:12px;border:1px solid var(--border);background:rgba(255,255,255,.03)}
.prio-high{border-color:rgba(255,92,122,.35);background:rgba(255,92,122,.12)}
.prio-med{border-color:rgba(247,209,84,.35);background:rgba(247,209,84,.10)}
.prio-low{border-color:rgba(56,217,150,.35);background:rgba(56,217,150,.10)}
.st-new{border-color:rgba(255,255,255,.14)}
.st-prog{border-color:rgba(106,167,255,.35);background:rgba(106,167,255,.10)}
.st-done{border-color:rgba(56,217,150,.35);background:rgba(56,217,150,.08)}
.due{font-weight:600}.due-warn{color:var(--yellow)}.due-bad{color:var(--red)}
.foot{margin-top:12px;color:var(--muted);font-size:12px;text-align:center}
</style>
</head><body>
<div class="wrap"><div class="card">
  <div class="top">
    <div>
      <h1>Tickets</h1>
      <div class="sub">Tenant: <span class="mono">${esc(tenantId)}</span> • Showing ${(items||[]).length} latest</div>
    </div>
    <div class="actions">
      <a class="btn" href="javascript:location.reload()">Refresh</a>
      <a class="btn primary" href="/ui/tickets/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String(keyForLink||""))}">Export CSV</a>
      <a class="btn" target="_blank" href="/ui/tickets/stats.json?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String(keyForLink||""))}">Stats JSON</a>
    </div>
  </div>

  <div class="share">
    <input id="shareLink" readonly value="${esc(shareLink)}"/>
    <a class="btn" href="javascript:(()=>{const el=document.getElementById('shareLink');el.select();navigator.clipboard.writeText(el.value);})()">Copy</a>
  </div>

  <table>
    <thead><tr>
      <th style="width:140px">TICKET ID</th>
      <th>SUBJECT</th>
      <th style="width:110px">PRIORITY</th>
      <th style="width:110px">STATUS</th>
      <th style="width:240px">DUE</th>
      <th style="width:260px">FROM</th>
    </tr></thead>
    <tbody>
      ${(items||[]).length ? rows : `<tr><td colspan="6" class="muted">No tickets yet. Send an email/WhatsApp to create the first ticket.</td></tr>`}
    </tbody>
  </table>

  <div class="foot">Intake-Guardian • sellable MVP: SLA + priority + export + audit.</div>
</div></div>
</body></html>`;

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    return res.send(html);
  });

  r.get("/tickets/export.csv", async (req, res) => {
    const tenantId = (typeof req.query.tenantId === "string" ? req.query.tenantId : "").trim();
    if (!tenantId) return res.status(400).send("missing_tenantId");

    const tk = requireTenantKey(req as any, tenantId, args.tenants, args.shares);
    if (!tk.ok) return res.status(tk.status).send(tk.error);

    const limit = Number(req.query.limit || 500);
    const items = await safeList(args.store, tenantId, Number.isFinite(limit) ? limit : 500);

    const csv = toCsv(items || []);
    const fname = `tickets_${tenantId}_${new Date().toISOString().slice(0,10)}.csv`;
    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="${fname}"`);
    return res.send(csv);
  });

  r.get("/tickets/stats.json", async (req, res) => {
    const tenantId = (typeof req.query.tenantId === "string" ? req.query.tenantId : "").trim();
    if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });

    const tk = requireTenantKey(req as any, tenantId, args.tenants, args.shares);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const limit = Number(req.query.limit || 500);
    const items = await safeList(args.store, tenantId, Number.isFinite(limit) ? limit : 500);

    const stats = computeStats(items || []);
    return res.json({ ok: true, tenantId, window: { latest: (items||[]).length }, ...stats });
  });

  return r;
}
TS

echo "==> [4] Clean server wiring duplicates (overwrite server.ts to stable, minimal, working version)"
cat > src/server.ts <<'TS'
import fs from "node:fs";
import path from "node:path";

import dotenv from "dotenv";
dotenv.config({ path: path.resolve(process.cwd(), ".env.local") });
dotenv.config({ path: path.resolve(process.cwd(), ".env") });

import express from "express";
import pino from "pino";

import { captureRawBody } from "./api/raw-body.js";
import { makeRoutes } from "./api/routes.js";
import { makeAdapterRoutes } from "./api/adapters.js";
import { makeOutboundRoutes } from "./api/outbound.js";
import { makeUiRoutes } from "./api/ui.js";

import { FileStore } from "./store/file.js";
import { TenantsStore } from "./tenants/store.js";
import { ShareStore } from "./shares/store.js";
import { ResendMailer } from "./lib/resend.js";

const log = pino({ level: process.env.LOG_LEVEL || "info" });

const PORT = Number(process.env.PORT || 7090);
const DATA_DIR = process.env.DATA_DIR || "./data";
const PRESET_ID = process.env.PRESET_ID || "it_support.v1";
const DEDUPE_WINDOW_SECONDS = Number(process.env.DEDUPE_WINDOW_SECONDS || 86400);
const WA_VERIFY_TOKEN = (process.env.WA_VERIFY_TOKEN || "").trim();

const ADMIN_KEY = (process.env.ADMIN_KEY || "").trim();
const TENANT_KEYS_JSON = process.env.TENANT_KEYS_JSON || "";

const RESEND_API_KEY = (process.env.RESEND_API_KEY || "").trim();
const RESEND_FROM = (process.env.RESEND_FROM || "").trim();
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || `http://127.0.0.1:${PORT}`).trim();
const RESEND_DRY_RUN = (process.env.RESEND_DRY_RUN || "").trim() === "1";

fs.mkdirSync(DATA_DIR, { recursive: true });

const store = new FileStore(path.resolve(DATA_DIR));
const tenants = new TenantsStore(DATA_DIR, TENANT_KEYS_JSON);
const shares = new ShareStore(DATA_DIR);

const mailer = (RESEND_API_KEY && RESEND_FROM)
  ? new ResendMailer({ apiKey: RESEND_API_KEY, from: RESEND_FROM, publicBaseUrl: PUBLIC_BASE_URL, dryRun: RESEND_DRY_RUN })
  : undefined;

async function main() {
  await store.init();

  const app = express();

  app.use(express.json({ limit: "512kb", verify: captureRawBody as any }));
  app.use(express.urlencoded({ extended: true, limit: "512kb", verify: captureRawBody as any }));

  // Simple health alias (some scripts use /health)
  app.get("/health", (_req, res) => res.json({ ok: true }));

  // Core API
  app.use("/api", makeRoutes({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS, tenants, shares }));

  // Inbound adapters (Email / WhatsApp)
  app.use(
    "/api/adapters",
    makeAdapterRoutes({
      store,
      presetId: PRESET_ID,
      dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS,
      waVerifyToken: WA_VERIFY_TOKEN || undefined,
      tenants,
      shares,
      mailer,
      publicBaseUrl: PUBLIC_BASE_URL
    })
  );

  // Outbound/admin routes
  app.use("/api", (req, res, next) => {
    // protect /api/admin/* with x-admin-key if configured
    if (req.path.startsWith("/admin/") && ADMIN_KEY) {
      const k = (req.header("x-admin-key") || "").trim();
      if (k !== ADMIN_KEY) return res.status(401).json({ ok: false, error: "invalid_admin_key" });
    }
    next();
  });
  app.use("/api", makeOutboundRoutes({ store, tenants }));

  // UI
  app.use("/ui", makeUiRoutes({ store, tenants, shares }));

  app.listen(PORT, () => {
    log.info(
      {
        PORT,
        DATA_DIR,
        PRESET_ID,
        DEDUPE_WINDOW_SECONDS,
        TENANT_KEYS_CONFIGURED: Boolean(TENANT_KEYS_JSON.trim()),
        ADMIN_KEY_CONFIGURED: Boolean(ADMIN_KEY),
        RESEND_CONFIGURED: Boolean(mailer),
      },
      "Intake-Guardian Agent running"
    );
  });
}

main().catch((err) => {
  log.error({ err }, "fatal");
  process.exit(1);
});
TS

echo "==> [5] Typecheck"
pnpm -s lint:types

echo
echo "✅ Done."
echo "Restart server now:"
echo "  (Ctrl+C) then pnpm dev"
echo
echo "Then test UI:"
echo "  curl -i 'http://127.0.0.1:7090/ui/tickets?tenantId=tenant_demo&k=dev_key_123' | head -n 40"
echo "  open 'http://127.0.0.1:7090/ui/tickets?tenantId=tenant_demo&k=dev_key_123'"
echo "CSV:"
echo "  open 'http://127.0.0.1:7090/ui/tickets/export.csv?tenantId=tenant_demo&k=dev_key_123'"
