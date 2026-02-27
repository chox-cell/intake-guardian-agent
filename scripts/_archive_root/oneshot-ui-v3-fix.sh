#!/usr/bin/env bash
set -euo pipefail

# OneShot UI/Export/Email v3 — FIX PACK
# - Unify ShareStore import (src/shares/* as SSOT) + compatibility re-export (src/share/*)
# - Fix TenantsStore constructor so it never crashes on non-string seed (TENANT_KEYS_JSON)
# - Provide ResendMailer.sendReceipt()
# - Make requireTenantKey support: header x-tenant-key OR query ?k= OR share token ?s=
# - Provide /ui/tickets + /ui/tickets/export.csv + /ui/tickets/stats.json (Express HTML)
# - Patch server.ts imports + wiring (best-effort, safe markers)
# - Patch adapters.ts imports/types (best-effort)

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
echo "==> OneShot FIX PACK @ $ROOT ($TS)"

backup_file() {
  local f="$1"
  if [ -f "$f" ]; then
    cp -a "$f" "$f.bak.$TS"
    echo "  backup: $f -> $f.bak.$TS"
  fi
}

echo "==> [0] Backups"
backup_file "src/server.ts"
backup_file "src/api/adapters.ts"
backup_file "src/api/outbound.ts"
backup_file "src/api/tenant-key.ts"
backup_file "src/api/ui.ts"
backup_file "src/tenants/store.ts"
backup_file "src/shares/store.ts"
backup_file "src/share/store.ts"
backup_file "src/lib/resend.ts"
backup_file "tsconfig.json"

echo "==> [1] Ensure dirs"
mkdir -p src/shares src/share src/tenants src/lib src/api

echo "==> [2] Write ShareStore (SSOT) + compatibility re-export"
cat > src/shares/store.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type ShareRecord = {
  token: string;
  tenantId: string;
  createdAt: string;
  expiresAt?: string;
};

function safeReadJson(p: string): any {
  try {
    if (!fs.existsSync(p)) return null;
    const raw = fs.readFileSync(p, "utf8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function safeWriteJson(p: string, data: any) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(data, null, 2), "utf8");
}

function nowISO() {
  return new Date().toISOString();
}

function randToken(len = 32) {
  return crypto.randomBytes(len).toString("base64url");
}

/**
 * ShareStore is a tiny token service:
 * - create(tenantId) => { token }
 * - get(token) => ShareRecord | null
 * - verify(tenantId, token) => boolean
 */
export class ShareStore {
  private filePath: string;
  private shares: Record<string, ShareRecord>;

  constructor(dataDir = "./data") {
    this.filePath = path.join(dataDir, "shares.json");
    const j = safeReadJson(this.filePath);
    this.shares = (j && typeof j === "object" && j.shares) ? j.shares : {};
  }

  private persist() {
    safeWriteJson(this.filePath, { shares: this.shares });
  }

  create(tenantId: string, ttlSeconds: number = 60 * 60 * 24 * 30) {
    const token = randToken(18);
    const rec: ShareRecord = {
      token,
      tenantId,
      createdAt: nowISO(),
      expiresAt: new Date(Date.now() + ttlSeconds * 1000).toISOString(),
    };
    this.shares[token] = rec;
    this.persist();
    return { token };
  }

  get(token: string): ShareRecord | null {
    const rec = this.shares[token];
    if (!rec) return null;
    if (rec.expiresAt && Date.parse(rec.expiresAt) < Date.now()) return null;
    return rec;
  }

  verify(tenantId: string, token: string): boolean {
    const rec = this.get(token);
    return !!rec && rec.tenantId === tenantId;
  }
}
TS

cat > src/share/store.ts <<'TS'
// Compatibility layer: some files import from "./share/store.js"
// SSOT is "./shares/store.js"
export { ShareStore } from "../shares/store.js";
export type { ShareRecord } from "../shares/store.js";
TS

echo "==> [3] Write TenantsStore (no crash on seed types)"
cat > src/tenants/store.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

type TenantRec = { tenantId: string; keyHash: string; createdAt: string; rotatedAt?: string };

function sha256(s: string) {
  return crypto.createHash("sha256").update(s).digest("hex");
}

function nowISO() {
  return new Date().toISOString();
}

function safeReadJson(p: string): any {
  try {
    if (!fs.existsSync(p)) return null;
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return null;
  }
}

function safeWriteJson(p: string, data: any) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(data, null, 2), "utf8");
}

function normalizeSeed(seed: unknown): Record<string, string> {
  if (!seed) return {};
  if (typeof seed === "string") {
    const raw = seed.trim();
    if (!raw) return {};
    try {
      const j = JSON.parse(raw);
      if (j && typeof j === "object") return j as any;
      return {};
    } catch {
      return {};
    }
  }
  // if object already provided (was the crash cause)
  if (typeof seed === "object") {
    try {
      return seed as any;
    } catch {
      return {};
    }
  }
  return {};
}

export class TenantsStore {
  private filePath: string;
  private tenants: Record<string, TenantRec>;

  /**
   * constructor(dataDir, seedJsonOrObject?)
   * - seed can be JSON string or object { [tenantId]: tenantKey }
   */
  constructor(dataDir = "./data", seed?: unknown) {
    this.filePath = path.join(dataDir, "tenants.json");
    const j = safeReadJson(this.filePath);
    this.tenants = (j && typeof j === "object" && j.tenants) ? j.tenants : {};

    // Merge seed keys (dev friendly)
    const seedMap = normalizeSeed(seed);
    for (const [tenantId, tenantKey] of Object.entries(seedMap)) {
      if (!tenantId || !tenantKey) continue;
      if (!this.tenants[tenantId]) {
        this.tenants[tenantId] = {
          tenantId,
          keyHash: sha256(String(tenantKey)),
          createdAt: nowISO(),
        };
      } else {
        // keep existing hash; seed shouldn't rotate silently
      }
    }
    this.persist();
  }

  private persist() {
    safeWriteJson(this.filePath, { tenants: this.tenants });
  }

  list() {
    return Object.values(this.tenants).sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1));
  }

  verify(tenantId: string, tenantKey: string): boolean {
    const rec = this.tenants[tenantId];
    if (!rec) return false;
    return rec.keyHash === sha256(String(tenantKey));
  }

  upsertNew(tenantId?: string) {
    const id = tenantId || `tenant_${Date.now()}`;
    if (this.tenants[id]) {
      return { tenantId: id, created: false, tenantKey: "" };
    }
    const key = crypto.randomBytes(24).toString("base64url");
    this.tenants[id] = { tenantId: id, keyHash: sha256(key), createdAt: nowISO() };
    this.persist();
    return { tenantId: id, created: true, tenantKey: key };
  }

  rotate(tenantId: string) {
    const rec = this.tenants[tenantId];
    if (!rec) return { ok: false as const, error: "tenant_not_found" as const };
    const key = crypto.randomBytes(24).toString("base64url");
    rec.keyHash = sha256(key);
    rec.rotatedAt = nowISO();
    this.tenants[tenantId] = rec;
    this.persist();
    return { ok: true as const, tenantId, tenantKey: key };
  }
}
TS

echo "==> [4] Write ResendMailer with sendReceipt()"
cat > src/lib/resend.ts <<'TS'
type ReceiptArgs = {
  to: string;
  subject: string;
  ticketId: string;
  tenantId: string;
  dueAtISO?: string;
  slaSeconds?: number;
  priority?: string;
  status?: string;
  shareUrl?: string;
};

function esc(s: string) {
  return String(s || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export class ResendMailer {
  private apiKey?: string;
  private from?: string;
  private publicBaseUrl?: string;
  private dryRun?: boolean;

  constructor(args: { apiKey?: string; from?: string; publicBaseUrl?: string; dryRun?: boolean }) {
    this.apiKey = args.apiKey;
    this.from = args.from;
    this.publicBaseUrl = args.publicBaseUrl;
    this.dryRun = args.dryRun;
  }

  isConfigured() {
    return !!(this.apiKey && this.from);
  }

  async sendReceipt(args: ReceiptArgs) {
    if (!this.isConfigured()) return { ok: false, error: "resend_not_configured" as const };
    if (this.dryRun) {
      // safe mode: never sends, but returns ok
      return { ok: true, dryRun: true as const };
    }

    const html = `
      <div style="font-family: ui-sans-serif, system-ui; line-height:1.4">
        <h2 style="margin:0 0 12px">✅ Ticket created</h2>
        <p style="margin:0 0 8px">Ticket ID: <b>${esc(args.ticketId)}</b></p>
        <p style="margin:0 0 8px">Priority: <b>${esc(args.priority || "unknown")}</b> · Status: <b>${esc(args.status || "new")}</b></p>
        <p style="margin:0 0 8px">Due: <b>${esc(args.dueAtISO || "-")}</b></p>
        ${args.shareUrl ? `<p style="margin:12px 0 0"><a href="${esc(args.shareUrl)}">Open tickets dashboard</a></p>` : ""}
        <hr style="margin:16px 0;border:none;border-top:1px solid #eee"/>
        <p style="color:#666;font-size:12px;margin:0">Intake-Guardian • proof UI (MVP)</p>
      </div>
    `.trim();

    const payload = {
      from: this.from,
      to: args.to,
      subject: args.subject,
      html,
    };

    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${this.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });

    if (!r.ok) {
      const txt = await r.text().catch(() => "");
      return { ok: false as const, error: "resend_send_failed" as const, status: r.status, body: txt };
    }

    return { ok: true as const };
  }
}
TS

echo "==> [5] Write tenant-key helper (header OR ?k= OR ?s= share token)"
cat > src/api/tenant-key.ts <<'TS'
import type { Request } from "express";
import type { TenantsStore } from "../tenants/store.js";
import type { ShareStore } from "../shares/store.js";

export function requireTenantKey(
  req: Request,
  tenantId: string,
  tenants?: TenantsStore,
  shares?: ShareStore
) {
  // 1) direct tenant key: header or query (?k=)
  const key =
    (req.header("x-tenant-key") || "").trim() ||
    (typeof req.query.k === "string" ? req.query.k.trim() : "");

  if (key && tenants && tenants.verify(tenantId, key)) return key;

  // 2) share token (?s=)
  const s = (typeof req.query.s === "string" ? req.query.s.trim() : "");
  if (s && shares && shares.verify(tenantId, s)) return s;

  // 3) fallback: if no tenants store wired, accept key (dev)
  if (!tenants && key) return key;

  return null;
}
TS

echo "==> [6] Write UI routes (Express HTML + export + stats)"
cat > src/api/ui.ts <<'TS'
import express from "express";
import type { Store } from "../store/types.js";
import type { TenantsStore } from "../tenants/store.js";
import type { ShareStore } from "../shares/store.js";
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
  if (id.length <= 12) return id;
  return id.slice(0, 6) + "…" + id.slice(-4);
}

function msUntil(iso?: string) {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return null;
  return t - Date.now();
}

function humanDelta(ms: number) {
  const s = Math.floor(Math.abs(ms) / 1000);
  const m = Math.floor(s / 60);
  const h = Math.floor(m / 60);
  if (h >= 48) return `${Math.floor(h / 24)}d`;
  if (h >= 1) return `${h}h`;
  return `${Math.max(1, m)}m`;
}

function badge(kind: string, val: string) {
  const v = (val || "").toLowerCase();
  let cls = "badge";
  if (kind === "priority") {
    cls += v === "high" ? " prio-high" : v === "medium" ? " prio-med" : " prio-low";
  } else if (kind === "status") {
    cls += v === "done" ? " st-done" : v === "in_progress" ? " st-prog" : " st-new";
  }
  return `<span class="${cls}">${esc(val)}</span>`;
}

function dueCell(dueAt?: string) {
  const ms = msUntil(dueAt);
  if (ms === null) return `<span class="muted">-</span>`;
  if (ms < 0) return `<span class="due due-bad">Overdue ${esc(humanDelta(ms))}</span><div class="muted mono">${esc(dueAt)}</div>`;
  if (ms <= 2 * 60 * 60 * 1000) return `<span class="due due-warn">Due in ${esc(humanDelta(ms))}</span><div class="muted mono">${esc(dueAt)}</div>`;
  return `<span class="due">Due in ${esc(humanDelta(ms))}</span><div class="muted mono">${esc(dueAt)}</div>`;
}

function computeStats(items: any[]) {
  const totals = { items: items.length };
  const byStatus: Record<string, number> = {};
  const byPriority: Record<string, number> = {};
  const byCategory: Record<string, number> = {};
  for (const it of items) {
    const st = (it.status || "unknown").toLowerCase();
    const pr = (it.priority || "unknown").toLowerCase();
    const cat = (it.category || "unknown").toLowerCase();
    byStatus[st] = (byStatus[st] || 0) + 1;
    byPriority[pr] = (byPriority[pr] || 0) + 1;
    byCategory[cat] = (byCategory[cat] || 0) + 1;
  }
  return { totals, byStatus, byPriority, byCategory };
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

export function makeUiRoutes(args: { store: Store; tenants: TenantsStore; shares: ShareStore }) {
  const r = express.Router();

  r.get("/tickets", async (req, res) => {
    const tenantId = (typeof req.query.tenantId === "string" ? req.query.tenantId : "").trim();
    if (!tenantId) return res.status(400).send("missing_tenantId");

    const token = requireTenantKey(req, tenantId, args.tenants, args.shares);
    if (!token) return res.status(401).send("invalid_tenant_key");

    const limit = Number(req.query.limit || 50);
    const items = await args.store.listWorkItems({ tenantId, limit: Number.isFinite(limit) ? limit : 50 });

    const shareToken = (typeof req.query.k === "string" && req.query.k) ? req.query.k : (typeof req.query.s === "string" ? req.query.s : "");
    const shareLink = `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String(shareToken || token))}`;

    const rows = items.map((it: any) => `
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
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Tickets — ${esc(tenantId)}</title>
  <style>
    :root{
      --bg:#060709; --card:#0b0d10; --border:rgba(255,255,255,.08);
      --text:#e8eaed; --muted:rgba(232,234,237,.6);
      --green:#38d996; --red:#ff5c7a; --yellow:#f7d154; --blue:#6aa7ff;
    }
    body{margin:0;font-family:ui-sans-serif,system-ui;background:radial-gradient(1200px 600px at 20% 10%, rgba(56,217,150,.18), transparent 55%),
                                              radial-gradient(1000px 500px at 70% 20%, rgba(106,167,255,.12), transparent 55%),
                                              var(--bg); color:var(--text);}
    .wrap{max-width:1100px;margin:28px auto;padding:0 18px;}
    .card{background:linear-gradient(180deg, rgba(255,255,255,.04), rgba(255,255,255,.02));
          border:1px solid var(--border); border-radius:18px; padding:18px 18px; box-shadow: 0 12px 40px rgba(0,0,0,.35);}
    .top{display:flex;justify-content:space-between;align-items:flex-start;gap:14px;}
    h1{margin:0;font-size:26px;letter-spacing:.2px}
    .sub{margin-top:6px;color:var(--muted);font-size:13px}
    .actions{display:flex;gap:10px;flex-wrap:wrap;justify-content:flex-end}
    .btn{border:1px solid var(--border);background:rgba(255,255,255,.04);color:var(--text);
         padding:10px 12px;border-radius:12px;text-decoration:none;font-size:13px;cursor:pointer}
    .btn:hover{background:rgba(255,255,255,.08)}
    .btn.primary{background:rgba(56,217,150,.18);border-color:rgba(56,217,150,.35)}
    .btn.primary:hover{background:rgba(56,217,150,.24)}
    .share{margin-top:14px;display:flex;gap:10px;align-items:center}
    .share input{flex:1;background:rgba(0,0,0,.35);border:1px dashed rgba(255,255,255,.18);color:var(--text);
                 padding:10px 12px;border-radius:12px;font-size:12px}
    table{width:100%;border-collapse:separate;border-spacing:0;margin-top:16px;overflow:hidden;border-radius:14px;border:1px solid var(--border)}
    thead th{background:rgba(255,255,255,.03);text-align:left;font-size:11px;color:var(--muted);padding:12px 12px;letter-spacing:.14em}
    tbody td{padding:14px 12px;border-top:1px solid var(--border);font-size:13px;vertical-align:top}
    tbody tr:hover{background:rgba(255,255,255,.03)}
    .mono{font-family:ui-monospace, SFMono-Regular, Menlo, monospace}
    .muted{color:var(--muted)}
    .subject{max-width:420px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .badge{display:inline-flex;align-items:center;gap:6px;padding:6px 10px;border-radius:999px;font-size:12px;border:1px solid var(--border);background:rgba(255,255,255,.03)}
    .prio-high{border-color:rgba(255,92,122,.35);background:rgba(255,92,122,.12)}
    .prio-med{border-color:rgba(247,209,84,.35);background:rgba(247,209,84,.10)}
    .prio-low{border-color:rgba(56,217,150,.35);background:rgba(56,217,150,.10)}
    .st-new{border-color:rgba(255,255,255,.14)}
    .st-prog{border-color:rgba(106,167,255,.35);background:rgba(106,167,255,.10)}
    .st-done{border-color:rgba(56,217,150,.35);background:rgba(56,217,150,.08)}
    .due{font-weight:600}
    .due-warn{color:var(--yellow)}
    .due-bad{color:var(--red)}
    .foot{margin-top:12px;color:var(--muted);font-size:12px;text-align:center}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="top">
        <div>
          <h1>Tickets</h1>
          <div class="sub">Tenant: <span class="mono">${esc(tenantId)}</span> • Showing ${items.length} latest</div>
        </div>
        <div class="actions">
          <button class="btn" onclick="location.reload()">Refresh</button>
          <button class="btn" onclick="copyShare()">Copy Share Link</button>
          <a class="btn primary" href="/ui/tickets/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String(token))}">Export CSV</a>
          <a class="btn" target="_blank" href="/ui/tickets/stats.json?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String(token))}">Stats (JSON)</a>
        </div>
      </div>

      <div class="share">
        <input id="shareLink" readonly value="${esc(shareLink)}"/>
      </div>

      <table>
        <thead>
          <tr>
            <th style="width:140px">TICKET ID</th>
            <th>SUBJECT</th>
            <th style="width:110px">PRIORITY</th>
            <th style="width:110px">STATUS</th>
            <th style="width:240px">DUE</th>
            <th style="width:260px">FROM</th>
          </tr>
        </thead>
        <tbody>
          ${items.length ? rows : `<tr><td colspan="6" class="muted">No tickets yet. Send an email/WhatsApp message to create the first ticket.</td></tr>`}
        </tbody>
      </table>

      <div class="foot">Intake-Guardian • proof UI (sellable MVP): SLA, priority, export — ready for teams.</div>
    </div>
  </div>

  <script>
    function copyShare(){
      const el = document.getElementById('shareLink');
      if(!el) return;
      el.select(); el.setSelectionRange(0, 99999);
      navigator.clipboard.writeText(el.value).catch(()=>{});
    }
  </script>
</body>
</html>`;

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    return res.send(html);
  });

  r.get("/tickets/export.csv", async (req, res) => {
    const tenantId = (typeof req.query.tenantId === "string" ? req.query.tenantId : "").trim();
    if (!tenantId) return res.status(400).send("missing_tenantId");

    const token = requireTenantKey(req, tenantId, args.tenants, args.shares);
    if (!token) return res.status(401).send("invalid_tenant_key");

    const limit = Number(req.query.limit || 500);
    const items = await args.store.listWorkItems({ tenantId, limit: Number.isFinite(limit) ? limit : 500 });

    const csv = toCsv(items);
    const fname = `tickets_${tenantId}_${new Date().toISOString().slice(0,10)}.csv`;
    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="${fname}"`);
    return res.send(csv);
  });

  r.get("/tickets/stats.json", async (req, res) => {
    const tenantId = (typeof req.query.tenantId === "string" ? req.query.tenantId : "").trim();
    if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });

    const token = requireTenantKey(req, tenantId, args.tenants, args.shares);
    if (!token) return res.status(401).json({ ok: false, error: "invalid_tenant_key" });

    const limit = Number(req.query.limit || 500);
    const items = await args.store.listWorkItems({ tenantId, limit: Number.isFinite(limit) ? limit : 500 });

    const stats = computeStats(items);
    return res.json({ ok: true, tenantId, window: { latest: items.length }, ...stats });
  });

  return r;
}
TS

echo "==> [7] Fix outbound.ts to match TenantsStore shapes (safe rewrite)"
cat > src/api/outbound.ts <<'TS'
import express from "express";
import type { Store } from "../store/types.js";
import type { TenantsStore } from "../tenants/store.js";
import { requireTenantKey } from "./tenant-key.js";

export function makeOutboundRoutes(args: { store: Store; tenants: TenantsStore }) {
  const r = express.Router();

  // Admin list (requires x-admin-key at server level; server.ts should gate)
  r.get("/admin/tenants", (_req, res) => {
    return res.json({
      ok: true,
      tenants: args.tenants.list().map((t) => ({ tenantId: t.tenantId, createdAt: t.createdAt, rotatedAt: t.rotatedAt })),
    });
  });

  r.post("/admin/tenants/create", (req, res) => {
    const out = args.tenants.upsertNew();
    if (!out.created) return res.status(409).json({ ok: false, error: "tenant_exists", tenantId: out.tenantId });
    return res.json({ ok: true, tenantId: out.tenantId, tenantKey: out.tenantKey });
  });

  r.post("/admin/tenants/rotate", (req, res) => {
    const body = (req.body || {}) as any;
    if (!body.tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });
    const out = args.tenants.rotate(String(body.tenantId));
    if (!out.ok) return res.status(404).json({ ok: false, error: out.error });
    return res.json({ ok: true, tenantId: out.tenantId, tenantKey: out.tenantKey });
  });

  // Optional slack outbound stub (kept compatible with earlier demos)
  r.post("/slack", async (req, res) => {
    const tenantId = (typeof req.query.tenantId === "string" ? req.query.tenantId : "").trim();
    if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });

    const tk = requireTenantKey(req as any, tenantId, args.tenants, undefined);
    if (!tk) return res.status(401).json({ ok: false, error: "invalid_tenant_key" });

    const body = (req.body || {}) as any;
    const workItemId = String(body.workItemId || "");
    if (!workItemId) return res.status(400).json({ ok: false, error: "missing_workItemId" });

    const webhook = process.env.SLACK_WEBHOOK_URL;
    if (!webhook) return res.status(400).json({ ok: false, error: "missing_slack_webhook_url" });

    // Minimal payload
    const payload = { text: `New ticket ${workItemId} (tenant=${tenantId})` };
    const r2 = await fetch(webhook, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
    if (!r2.ok) return res.status(502).json({ ok: false, error: "slack_failed", status: r2.status });

    return res.json({ ok: true });
  });

  return r;
}
TS

echo "==> [8] Patch adapters.ts (best-effort: unify imports + sendReceipt existence)"
if [ -f src/api/adapters.ts ]; then
  node <<'NODE'
const fs = require("fs");
const p = "src/api/adapters.ts";
let s = fs.readFileSync(p, "utf8");

// 1) Ensure ShareStore import comes from ../shares/store.js
s = s.replaceAll('../share/store.js', '../shares/store.js');

// 2) Ensure tenant-key import exists and uses shares store type
// (No heavy rewrite: just normalize path if present)
s = s.replaceAll('./tenant-key.js', './tenant-key.js');

// 3) If code references args.mailer.sendReceipt, we already implemented it.
// No further changes unless it imports ResendMailer wrong path
s = s.replaceAll('../lib/resend.ts', '../lib/resend.js');
s = s.replaceAll('../lib/resend.js', '../lib/resend.js');

// 4) Fix common mistake: args.shares?.create(...) returning string. Our create returns {token}, so keep ".token" usage.
// If file contains "const token = args.shares?.create(tenantIdQ);" then convert to ".token"
s = s.replace(/const\s+token\s*=\s*args\.shares\?\.\s*create\(([^)]+)\)\s*;\s*/g, 'const token = args.shares?.create($1)?.token;\n');

fs.writeFileSync(p, s);
console.log("✅ patched", p);
NODE
else
  echo "⚠️ src/api/adapters.ts not found (skip)"
fi

echo "==> [9] Patch server.ts (best-effort wiring: tenants+shares+ui, fix duplicate imports, fix TenantsStore ctor)"
if [ -f src/server.ts ]; then
  node <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

// Remove duplicate ShareStore imports if both exist
s = s.replace(/import\s+\{\s*ShareStore\s*\}\s+from\s+"\.\/share\/store\.js";\s*\n/g, "");
// Keep SSOT import
if (!s.includes('from "./shares/store.js"') && s.includes("ShareStore")) {
  // insert after TenantsStore import if possible
  if (s.includes('from "./tenants/store.js"')) {
    s = s.replace('from "./tenants/store.js";', 'from "./tenants/store.js";\nimport { ShareStore } from "./shares/store.js";');
  } else if (!s.includes('import { ShareStore } from "./shares/store.js";')) {
    s = 'import { ShareStore } from "./shares/store.js";\n' + s;
  }
}

// Fix TenantsStore constructor usage that passed an object ({ dataDir })
s = s.replace(/new\s+TenantsStore\(\s*\{\s*dataDir:\s*DATA_DIR\s*\}\s*\)/g, "new TenantsStore(DATA_DIR, process.env.TENANT_KEYS_JSON)");
s = s.replace(/new\s+TenantsStore\(\s*\{\s*dataDir:\s*DATA_DIR,\s*seedJson:\s*TENANT_KEYS_JSON\s*\}\s*\)/g, "new TenantsStore(DATA_DIR, process.env.TENANT_KEYS_JSON)");

// Ensure shares init exists
if (!s.includes("const shares = new ShareStore")) {
  // place after tenants creation if found
  const m = s.match(/const\s+tenants\s*=\s*new\s+TenantsStore[^\n]*\n/);
  if (m) {
    s = s.replace(m[0], m[0] + "const shares = new ShareStore(DATA_DIR);\n");
  }
}

// Ensure UI mount exists
if (!s.includes('app.use("/ui"') && s.includes("makeUiRoutes")) {
  // mount near other app.use blocks - after adapters if possible
  s = s.replace(/app\.use\(\s*["']\/api\/adapters["'][\s\S]*?\);\s*\n/, (block) => {
    if (block.includes('app.use("/ui"')) return block;
    return block + `app.use("/ui", makeUiRoutes({ store, tenants, shares }));\n`;
  });
}
// If no adapters block match, just inject near end before listen
if (!s.includes('app.use("/ui"') && s.includes("makeUiRoutes")) {
  s = s.replace(/app\.listen\(/, `app.use("/ui", makeUiRoutes({ store, tenants, shares }));\n\napp.listen(`);
}

// Ensure adapters/outbound get shares + mailer if their factory supports it (non-fatal if not)
s = s.replace(/makeAdapterRoutes\(\{\s*store,\s*tenants,/g, "makeAdapterRoutes({ store, tenants, shares,");
s = s.replace(/makeAdapterRoutes\(\{\s*store,/g, "makeAdapterRoutes({ store, tenants, shares, store,");

// Fix mailer null → undefined if you have a ternary that returns null
s = s.replace(/:\s*null(\s*[;,\n])/g, ": undefined$1");

fs.writeFileSync(p, s);
console.log("✅ patched", p);
NODE
else
  echo "⚠️ src/server.ts not found (skip)"
fi

echo "==> [10] Patch tsconfig exclude backups (so lint:types won't include __bak_*)"
if [ -f tsconfig.json ]; then
  node <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p, "utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]),
  "node_modules","dist","build","__bak_*","__bak_salespack_*","**/*.bak.*",".bak"
]));
fs.writeFileSync(p, JSON.stringify(j, null, 2));
console.log("✅ patched", p);
NODE
fi

echo "==> [11] Typecheck"
pnpm -s lint:types

echo
echo "✅ FIX PACK applied."
echo
echo "Next:"
echo "  1) restart: pnpm dev"
echo "  2) open UI:"
echo "     http://127.0.0.1:7090/ui/tickets?tenantId=tenant_demo&k=dev_key_123"
echo "  3) export CSV:"
echo "     http://127.0.0.1:7090/ui/tickets/export.csv?tenantId=tenant_demo&k=dev_key_123"
echo "  4) stats JSON:"
echo "     http://127.0.0.1:7090/ui/tickets/stats.json?tenantId=tenant_demo&k=dev_key_123"
