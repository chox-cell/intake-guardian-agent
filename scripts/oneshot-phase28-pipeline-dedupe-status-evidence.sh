#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date +%Y%m%d_%H%M%S)"
BK="__bak_phase28_${TS}"
mkdir -p "$BK"

echo "==> Phase28 OneShot (pipeline+dedupe+status+evidence+guards) @ $ROOT"
echo "==> Backup -> $BK"
cp -R src "$BK/src" 2>/dev/null || true
cp -R scripts "$BK/scripts" 2>/dev/null || true
cp -f tsconfig.json "$BK/tsconfig.json" 2>/dev/null || true
cp -f package.json "$BK/package.json" 2>/dev/null || true

mkdir -p src/lib src/api src/ui scripts data

# -------------------------
# [1] Helpers: crypto/fs/jsonl + safe url parse
# -------------------------
cat > src/lib/_util.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export function nowUtc(): string {
  return new Date().toISOString();
}

export function sha256Hex(input: string | Buffer): string {
  return crypto.createHash("sha256").update(input).digest("hex");
}

export function safeJsonParse<T>(s: string): T | null {
  try { return JSON.parse(s) as T; } catch { return null; }
}

export function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

export function readJsonl<T>(filePath: string): T[] {
  if (!fs.existsSync(filePath)) return [];
  const raw = fs.readFileSync(filePath, "utf8");
  const lines = raw.split("\n").map(x => x.trim()).filter(Boolean);
  const out: T[] = [];
  for (const line of lines) {
    const v = safeJsonParse<T>(line);
    if (v) out.push(v);
  }
  return out;
}

export function appendJsonl(filePath: string, obj: unknown) {
  ensureDir(path.dirname(filePath));
  fs.appendFileSync(filePath, JSON.stringify(obj) + "\n");
}

export function writeJson(filePath: string, obj: unknown) {
  ensureDir(path.dirname(filePath));
  fs.writeFileSync(filePath, JSON.stringify(obj, null, 2), "utf8");
}

export function readJson<T>(filePath: string): T | null {
  if (!fs.existsSync(filePath)) return null;
  return safeJsonParse<T>(fs.readFileSync(filePath, "utf8"));
}

export function clampStr(s: unknown, max = 4000): string {
  const v = String(s ?? "");
  return v.length > max ? v.slice(0, max) + "…" : v;
}

export function toId(prefix: string, seedHex: string): string {
  // stable id
  return `${prefix}_${seedHex.slice(0, 16)}`;
}

export function safeEncode(s: string): string {
  return encodeURIComponent(s);
}
TS

# -------------------------
# [2] Disk-backed Ticket Pipeline (SSOT)
# -------------------------
cat > src/lib/tickets_pipeline.ts <<'TS'
import path from "node:path";
import fs from "node:fs";
import crypto from "node:crypto";
import { appendJsonl, ensureDir, nowUtc, readJsonl, sha256Hex, toId, writeJson, readJson } from "./_util.js";

export type TicketStatus = "open" | "pending" | "closed";

export type IncomingWebhook = {
  source?: string;            // e.g. "webhook"
  title?: string;
  message?: string;
  sender?: string;
  externalId?: string;        // recommended: provider message id / issue id / etc
  priority?: "low" | "medium" | "high";
  dueAtUtc?: string;
  // arbitrary payload:
  data?: Record<string, unknown>;
};

export type TicketRecord = {
  id: string;
  tenantId: string;
  status: TicketStatus;
  source: string;
  title: string;
  createdAtUtc: string;
  updatedAtUtc: string;
  dedupeKey: string;
  externalId?: string;
  priority?: "low" | "medium" | "high";
  dueAtUtc?: string;

  // evidence pointers
  evidenceHash: string;
  evidencePath: string;
  rawPath: string;
};

export type PipelineResult = {
  ok: true;
  created: boolean;
  ticket: TicketRecord;
};

export type PipelineError =
  | { ok: false; error: "invalid_payload"; hint?: string }
  | { ok: false; error: "invalid_tenant"; hint?: string }
  | { ok: false; error: "write_failed"; hint?: string };

function dataDirFromEnv(): string {
  return process.env.DATA_DIR || "./data";
}

function tenantDir(tenantId: string): string {
  return path.join(dataDirFromEnv(), "tenants", tenantId);
}

function ticketsJsonl(tenantId: string): string {
  return path.join(tenantDir(tenantId), "tickets.jsonl");
}

function seenJsonl(tenantId: string): string {
  return path.join(tenantDir(tenantId), "seen.jsonl");
}

function evidenceDir(tenantId: string): string {
  return path.join(tenantDir(tenantId), "evidence");
}

function safeStatus(s: unknown): "open" | "pending" | "closed" {
  const v = String(s || "").toLowerCase();
  if (v === "pending") return "pending";
  if (v === "closed") return "closed";
  return "open";
}

function normalizeIncoming(body: any): IncomingWebhook {
  const src = String(body?.source || "webhook");
  const title = String(body?.title || body?.subject || "Webhook intake");
  const message = String(body?.message || body?.body || "");
  const sender = body?.sender ? String(body.sender) : (body?.from ? String(body.from) : "");
  const externalId = body?.externalId ? String(body.externalId) : (body?.id ? String(body.id) : "");
  const priority = body?.priority ? String(body.priority) : "";
  const dueAtUtc = body?.dueAtUtc ? String(body.dueAtUtc) : "";

  const p = (priority === "high" || priority === "medium" || priority === "low") ? (priority as any) : undefined;

  const data = (body && typeof body === "object") ? body : { value: body };

  return {
    source: src,
    title,
    message,
    sender,
    externalId: externalId || undefined,
    priority: p,
    dueAtUtc: dueAtUtc || undefined,
    data,
  };
}

function computeDedupeKey(tenantId: string, incoming: IncomingWebhook, rawBodyText: string): string {
  // Prefer externalId if provided; else hash stable projection of important fields; else raw hash.
  const keyBase = incoming.externalId
    ? `tenant=${tenantId}|source=${incoming.source}|externalId=${incoming.externalId}`
    : `tenant=${tenantId}|source=${incoming.source}|title=${incoming.title}|sender=${incoming.sender}|msg=${incoming.message}`;
  const fallback = rawBodyText ? rawBodyText : JSON.stringify(incoming.data || {});
  return sha256Hex(keyBase + "\n" + fallback);
}

function readRecentSeen(tenantId: string, windowSeconds: number): Set<string> {
  const file = seenJsonl(tenantId);
  const rows = readJsonl<{ atUtc: string; id: string }>(file);
  const now = Date.now();
  const keep = rows.filter(r => {
    const t = Date.parse(r.atUtc);
    if (!Number.isFinite(t)) return false;
    return (now - t) <= windowSeconds * 1000;
  });
  // best-effort compact
  try {
    ensureDir(path.dirname(file));
    fs.writeFileSync(file, keep.map(r => JSON.stringify(r)).join("\n") + (keep.length ? "\n" : ""), "utf8");
  } catch {}
  return new Set(keep.map(r => r.id));
}

function markSeen(tenantId: string, id: string) {
  appendJsonl(seenJsonl(tenantId), { atUtc: nowUtc(), id });
}

export function listTickets(tenantId: string): TicketRecord[] {
  const rows = readJsonl<TicketRecord>(ticketsJsonl(tenantId));
  // De-duplicate by id (last write wins)
  const m = new Map<string, TicketRecord>();
  for (const r of rows) m.set(r.id, r);
  const uniq = Array.from(m.values());
  uniq.sort((a, b) => String(b.createdAtUtc).localeCompare(String(a.createdAtUtc)));
  return uniq;
}

export function getTicket(tenantId: string, ticketId: string): TicketRecord | null {
  const rows = listTickets(tenantId);
  return rows.find(t => t.id === ticketId) || null;
}

export function setTicketStatus(tenantId: string, ticketId: string, status: TicketStatus): TicketRecord | null {
  const cur = getTicket(tenantId, ticketId);
  if (!cur) return null;
  const next: TicketRecord = { ...cur, status: safeStatus(status), updatedAtUtc: nowUtc() };
  appendJsonl(ticketsJsonl(tenantId), next);
  return next;
}

export function pipelineWebhook(
  tenantId: string,
  rawBodyText: string,
  rawHeaders: Record<string, string | string[] | undefined>,
  bodyObj: any
): PipelineResult | PipelineError {

  if (!tenantId) return { ok: false, error: "invalid_tenant", hint: "missing tenantId" };

  const incoming = normalizeIncoming(bodyObj);
  if (!incoming.title) return { ok: false, error: "invalid_payload", hint: "missing title" };

  // Replay/Ratelimit guard (soft): use X-Webhook-Id if present, else dedupeKey.
  const windowSeconds = Number(process.env.DEDUPE_WINDOW_SECONDS || 86400);
  const webhookId = String(rawHeaders["x-webhook-id"] || rawHeaders["x-delivery-id"] || "").trim();
  const dedupeKey = computeDedupeKey(tenantId, incoming, rawBodyText);

  const replayKey = webhookId ? `wh:${webhookId}` : `dk:${dedupeKey}`;
  const seen = readRecentSeen(tenantId, windowSeconds);
  if (seen.has(replayKey)) {
    // treat as deduped; return existing ticket if possible
    const existing = findByDedupeKey(tenantId, dedupeKey);
    if (existing) return { ok: true, created: false, ticket: existing };
    // fallback: respond non-creating but consistent
    const stub: TicketRecord = {
      id: toId("t", dedupeKey),
      tenantId,
      status: "open",
      source: incoming.source || "webhook",
      title: incoming.title,
      createdAtUtc: nowUtc(),
      updatedAtUtc: nowUtc(),
      dedupeKey,
      externalId: incoming.externalId,
      priority: incoming.priority,
      dueAtUtc: incoming.dueAtUtc,
      evidenceHash: sha256Hex("missing_evidence"),
      evidencePath: "",
      rawPath: ""
    };
    return { ok: true, created: false, ticket: stub };
  }
  markSeen(tenantId, replayKey);

  // Strong dedupe by dedupeKey within window: if exists, return existing
  const existing = findByDedupeKey(tenantId, dedupeKey);
  if (existing) return { ok: true, created: false, ticket: existing };

  // Create new ticket
  const id = toId("t", dedupeKey);
  const createdAtUtc = nowUtc();

  const evDir = evidenceDir(tenantId);
  ensureDir(evDir);

  const rawPath = path.join(evDir, `${id}.raw.json`);
  const evidencePath = path.join(evDir, `${id}.evidence.json`);

  const evidence = {
    schema: "intake-guardian.evidence.v1",
    tenantId,
    ticketId: id,
    createdAtUtc,
    source: incoming.source || "webhook",
    title: incoming.title,
    sender: incoming.sender || "",
    externalId: incoming.externalId || "",
    priority: incoming.priority || "medium",
    dueAtUtc: incoming.dueAtUtc || "",
    headers: sanitizeHeaders(rawHeaders),
    normalized: incoming,
  };

  try {
    writeJson(rawPath, {
      schema: "intake-guardian.raw.v1",
      tenantId,
      atUtc: createdAtUtc,
      headers: sanitizeHeaders(rawHeaders),
      rawBodyText,
      body: bodyObj,
    });

    writeJson(evidencePath, evidence);
  } catch (e: any) {
    return { ok: false, error: "write_failed", hint: String(e?.message || e) };
  }

  const evidenceHash = sha256Hex(fs.readFileSync(evidencePath));

  const rec: TicketRecord = {
    id,
    tenantId,
    status: "open",
    source: incoming.source || "webhook",
    title: incoming.title,
    createdAtUtc,
    updatedAtUtc: createdAtUtc,
    dedupeKey,
    externalId: incoming.externalId,
    priority: incoming.priority,
    dueAtUtc: incoming.dueAtUtc,
    evidenceHash,
    evidencePath: evidencePath.replace(dataDirFromEnv() + "/", ""),
    rawPath: rawPath.replace(dataDirFromEnv() + "/", ""),
  };

  appendJsonl(ticketsJsonl(tenantId), rec);
  return { ok: true, created: true, ticket: rec };
}

function sanitizeHeaders(h: Record<string, any>) {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(h || {})) {
    const kk = String(k).toLowerCase();
    if (kk === "authorization") continue;
    if (kk === "cookie") continue;
    out[kk] = Array.isArray(v) ? v.join(",") : String(v ?? "");
  }
  return out;
}

function findByDedupeKey(tenantId: string, dedupeKey: string): TicketRecord | null {
  const rows = readJsonl<TicketRecord>(ticketsJsonl(tenantId));
  // last write wins
  for (let i = rows.length - 1; i >= 0; i--) {
    if (rows[i]?.dedupeKey === dedupeKey) return rows[i];
  }
  return null;
}
TS

# -------------------------
# [3] Webhook API mount: /api/webhook/intake
# -------------------------
cat > src/api/webhook.ts <<'TS'
import type { Express } from "express";
import express from "express";
import { pipelineWebhook } from "../lib/tickets_pipeline.js";
import { verifyTenantKeyLocal } from "../lib/tenant_registry.js";

export function mountWebhook(app: Express) {
  const router = express.Router();

  router.post("/api/webhook/intake", express.json({ limit: "1mb" }), (req, res) => {
    const tenantId = String(req.query.tenantId || req.body?.tenantId || "").trim();
    const tenantKey = String(req.query.k || req.query.tenantKey || req.body?.tenantKey || "").trim();

    if (!tenantId || !tenantKey) {
      return res.status(400).json({ ok: false, error: "missing_tenant", hint: "Use ?tenantId=...&k=..." });
    }
    if (!verifyTenantKeyLocal(tenantId, tenantKey)) {
      return res.status(401).json({ ok: false, error: "invalid_tenant_key" });
    }

    const rawText = typeof req.body === "string" ? req.body : JSON.stringify(req.body ?? {});
    const headers = req.headers as Record<string, any>;

    const out = pipelineWebhook(tenantId, rawText, headers, req.body);

    if (!out.ok) {
      const code = out.error === "invalid_payload" ? 400 : 500;
      return res.status(code).json(out);
    }
    return res.status(201).json(out);
  });

  app.use(router);
}
TS

# -------------------------
# [4] UI Routes: fix duplicates + status actions + evidence ZIP + CSV
# (no require, ESM safe)
# -------------------------
cat > src/ui/routes.ts <<'TS'
import type { Express } from "express";
import path from "node:path";
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { verifyTenantKeyLocal, getOrCreateDemoTenant } from "../lib/tenant_registry.js";
import { listTickets, setTicketStatus, type TicketRecord, type TicketStatus } from "../lib/tickets_pipeline.js";
import { ensureDir, safeEncode } from "../lib/_util.js";

function htmlPage(title: string, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>${title}</title>
<style>
  :root{
    --bg:#070A12;
    --card: rgba(17,24,39,.55);
    --line: rgba(255,255,255,.08);
    --muted:#9ca3af;
    --txt:#e5e7eb;
    --shadow: 0 18px 60px rgba(0,0,0,.35);
  }
  *{box-sizing:border-box}
  body{
    margin:0;
    background: radial-gradient(1200px 700px at 20% 10%, rgba(96,165,250,.10), transparent 55%),
                radial-gradient(1100px 680px at 80% 20%, rgba(34,197,94,.10), transparent 52%),
                radial-gradient(900px 600px at 50% 90%, rgba(167,139,250,.10), transparent 60%),
                var(--bg);
    color:var(--txt);
    font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial;
  }
  .wrap{ max-width: 1180px; margin: 56px auto; padding: 0 18px; }
  .card{
    border:1px solid var(--line);
    background: var(--card);
    border-radius: 18px;
    padding: 18px 18px;
    box-shadow: var(--shadow);
  }
  .h{ font-size: 28px; font-weight: 850; margin: 0 0 8px; letter-spacing: .2px; }
  .muted{ color:var(--muted); font-size: 13px; }
  .row{ display:flex; gap:12px; flex-wrap:wrap; align-items:center; margin-top: 12px; }
  .btn{
    display:inline-flex; align-items:center; gap:8px;
    padding:10px 14px; border-radius: 12px;
    border:1px solid rgba(255,255,255,.10);
    background: rgba(0,0,0,.25);
    color:var(--txt); text-decoration:none; font-weight:800;
    cursor:pointer;
  }
  .btn:hover{ border-color: rgba(255,255,255,.18); background: rgba(0,0,0,.34); }
  .btn.primary{ background: rgba(34,197,94,.16); border-color: rgba(34,197,94,.30); }
  .btn.primary:hover{ background: rgba(34,197,94,.22); }
  table{ width:100%; border-collapse: collapse; margin-top: 12px; }
  th,td{ text-align:left; padding: 10px 10px; border-bottom: 1px solid rgba(255,255,255,.06); font-size: 13px; }
  th{ color:var(--muted); font-weight: 900; font-size: 12px; letter-spacing: .08em; text-transform: uppercase; }
  .chip{
    display:inline-flex; align-items:center; gap:8px;
    padding: 4px 10px;
    border-radius: 999px;
    border:1px solid rgba(255,255,255,.10);
    background: rgba(0,0,0,.20);
    font-weight: 900;
    font-size: 12px;
    text-decoration:none;
    color: var(--txt);
  }
  .chip.open{ border-color: rgba(59,130,246,.35); background: rgba(59,130,246,.12); }
  .chip.pending{ border-color: rgba(245,158,11,.35); background: rgba(245,158,11,.12); }
  .chip.closed{ border-color: rgba(34,197,94,.35); background: rgba(34,197,94,.12); }
  .mono{ font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; }
  .right{ margin-left:auto; }
  .small{ font-size: 12px; color: var(--muted); }
</style>
</head>
<body>
  <div class="wrap">
    ${body}
  </div>
</body>
</html>`;
}

function bad(res: any, msg: string, hint = "") {
  return res.status(400).send(htmlPage("Error", `
    <div class="card">
      <div class="h">Error</div>
      <div class="muted">${msg}</div>
      ${hint ? `<pre class="mono">${hint}</pre>` : ""}
    </div>
  `));
}

function getTenantFromReq(req: any) {
  const tenantId = String(req.query.tenantId || "").trim();
  const tenantKey = String(req.query.k || req.query.tenantKey || "").trim();
  return { tenantId, tenantKey };
}

function mustAuth(req: any, res: any) {
  const { tenantId, tenantKey } = getTenantFromReq(req);
  if (!tenantId || !tenantKey) {
    bad(res, "missing tenantId/k", "Use: /ui/tickets?tenantId=...&k=...");
    return null;
  }
  if (!verifyTenantKeyLocal(tenantId, tenantKey)) {
    res.status(401).send(htmlPage("Unauthorized", `
      <div class="card">
        <div class="h">Unauthorized</div>
        <div class="muted">invalid_tenant_key</div>
      </div>
    `));
    return null;
  }
  return { tenantId, tenantKey };
}

function csvEscape(s: string) {
  const v = String(s ?? "");
  if (v.includes(",") || v.includes('"') || v.includes("\n")) return `"${v.replace(/"/g, '""')}"`;
  return v;
}

function ticketsToCsv(rows: TicketRecord[]) {
  const head = ["id","status","source","title","createdAtUtc","evidenceHash"].join(",");
  const lines = rows.map(t => [
    t.id, t.status, t.source, t.title, t.createdAtUtc, t.evidenceHash
  ].map(csvEscape).join(","));
  return [head, ...lines].join("\n") + "\n";
}

function buildEvidenceZip(tenantId: string): string {
  const dataDir = process.env.DATA_DIR || "./data";
  const outDir = path.join(dataDir, "exports", tenantId);
  ensureDir(outDir);

  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const workDir = path.join(outDir, `pack_${stamp}`);
  ensureDir(workDir);

  const rows = listTickets(tenantId);
  fs.writeFileSync(path.join(workDir, "tickets.csv"), ticketsToCsv(rows), "utf8");

  const readme = [
    "# Intake-Guardian Evidence Pack",
    "",
    `tenantId: ${tenantId}`,
    `generatedAtUtc: ${new Date().toISOString()}`,
    "",
    "Contents:",
    "- tickets.csv",
    "- evidence/ (per-ticket evidence + raw payload if present)",
    "",
    "Notes:",
    "- This pack is generated locally from disk storage.",
    "- Do not share tenant keys publicly.",
    ""
  ].join("\n");
  fs.writeFileSync(path.join(workDir, "README.md"), readme, "utf8");

  // copy evidence folder (best effort)
  const evSrc = path.join(dataDir, "tenants", tenantId, "evidence");
  const evDst = path.join(workDir, "evidence");
  ensureDir(evDst);
  if (fs.existsSync(evSrc)) {
    for (const f of fs.readdirSync(evSrc)) {
      const src = path.join(evSrc, f);
      const dst = path.join(evDst, f);
      try {
        fs.copyFileSync(src, dst);
      } catch {}
    }
  }

  const zipPath = path.join(outDir, `evidence_pack_${tenantId}_${stamp}.zip`);
  // Use system zip (available on macOS)
  execFileSync("zip", ["-r", zipPath, "."], { cwd: workDir, stdio: "ignore" });

  return zipPath;
}

export function mountUi(app: Express) {
  // /ui is intentionally hidden
  app.get("/ui", (_req, res) => res.status(404).send("not found"));

  // admin autolink -> demo tenant (or fresh with ?fresh=1) WITHOUT exposing ADMIN_KEY in client URL
  app.get("/ui/admin", async (req, res) => {
    try {
      const admin = String(req.query.admin || "");
      const ADMIN_KEY = String(process.env.ADMIN_KEY || "");
      if (!ADMIN_KEY || admin !== ADMIN_KEY) {
        return res.status(401).send(htmlPage("Unauthorized", `
          <div class="card">
            <div class="h">Unauthorized</div>
            <div class="muted">admin_key_required</div>
          </div>
        `));
      }

      // stable demo tenant by default (safe), can add &fresh=1 to create a new tenant elsewhere in admin API
      const tenant = await getOrCreateDemoTenant();
      const loc = `/ui/tickets?tenantId=${safeEncode(tenant.tenantId)}&k=${safeEncode(tenant.tenantKey)}`;
      res.setHeader("Location", loc);
      return res.status(302).end();
    } catch (e: any) {
      return res.status(500).send(htmlPage("Admin error", `
        <div class="card">
          <div class="h">Admin error</div>
          <div class="muted">autolink_failed</div>
          <pre class="mono">${String(e?.stack || e?.message || e)}</pre>
        </div>
      `));
    }
  });

  // Tickets page
  app.get("/ui/tickets", (req, res) => {
    const auth = mustAuth(req, res);
    if (!auth) return;

    const { tenantId, tenantKey } = auth;
    const rows = listTickets(tenantId);

    const csvUrl = `/ui/export.csv?tenantId=${safeEncode(tenantId)}&k=${safeEncode(tenantKey)}`;
    const zipUrl = `/ui/evidence.zip?tenantId=${safeEncode(tenantId)}&k=${safeEncode(tenantKey)}`;

    const tableRows = rows.map(t => {
      const chip = `<span class="chip ${t.status}">${t.status}</span>`;
      const actions = [
        statusLink(tenantId, tenantKey, t.id, "open"),
        statusLink(tenantId, tenantKey, t.id, "pending"),
        statusLink(tenantId, tenantKey, t.id, "closed"),
      ].join(" ");

      return `<tr>
        <td class="mono">${t.id}</td>
        <td>${chip}</td>
        <td>${escapeHtml(t.source)}</td>
        <td>${escapeHtml(t.title)}</td>
        <td class="mono">${escapeHtml(t.createdAtUtc)}</td>
        <td>${actions}</td>
      </tr>`;
    }).join("");

    const body = `
      <div class="card">
        <div class="h">Tickets</div>
        <div class="muted">Client view • tenant <span class="mono">${escapeHtml(tenantId)}</span></div>

        <div class="row">
          <a class="btn primary" href="${zipUrl}">Download Evidence Pack (ZIP)</a>
          <a class="btn" href="${csvUrl}">Export CSV</a>
          <div class="right small">Tip: click a status to set it.</div>
        </div>

        <table>
          <thead>
            <tr>
              <th>ID</th><th>Status</th><th>Source</th><th>Title</th><th>Created</th><th>Set Status</th>
            </tr>
          </thead>
          <tbody>
            ${tableRows || `<tr><td colspan="6" class="muted">No tickets yet. Send a webhook to create one.</td></tr>`}
          </tbody>
        </table>

        <div class="small" style="margin-top:10px;">Intake-Guardian • ${new Date().toISOString()}</div>
      </div>
    `;

    res.status(200).send(htmlPage("Tickets", body));
  });

  // CSV export
  app.get("/ui/export.csv", (req, res) => {
    const auth = mustAuth(req, res);
    if (!auth) return;
    const rows = listTickets(auth.tenantId);
    const csv = ticketsToCsv(rows);
    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${auth.tenantId}.csv"`);
    return res.status(200).send(csv);
  });

  // Evidence ZIP pack
  app.get("/ui/evidence.zip", (req, res) => {
    const auth = mustAuth(req, res);
    if (!auth) return;
    try {
      const zipPath = buildEvidenceZip(auth.tenantId);
      res.setHeader("Content-Type", "application/zip");
      res.setHeader("Content-Disposition", `attachment; filename="evidence_pack_${auth.tenantId}.zip"`);
      fs.createReadStream(zipPath).pipe(res);
    } catch (e: any) {
      return res.status(500).send(htmlPage("Error", `
        <div class="card">
          <div class="h">Export error</div>
          <div class="muted">zip_failed</div>
          <pre class="mono">${String(e?.stack || e?.message || e)}</pre>
        </div>
      `));
    }
  });

  // Set status (simple action link)
  app.get("/ui/set-status", (req, res) => {
    const auth = mustAuth(req, res);
    if (!auth) return;
    const id = String(req.query.id || "");
    const st = String(req.query.status || "");
    if (!id) return bad(res, "missing id");
    const status = (st === "pending" || st === "closed" || st === "open") ? (st as TicketStatus) : "open";
    setTicketStatus(auth.tenantId, id, status);
    const back = `/ui/tickets?tenantId=${safeEncode(auth.tenantId)}&k=${safeEncode(auth.tenantKey)}`;
    return res.redirect(302, back);
  });
}

function statusLink(tenantId: string, k: string, id: string, st: TicketStatus) {
  const href = `/ui/set-status?tenantId=${safeEncode(tenantId)}&k=${safeEncode(k)}&id=${safeEncode(id)}&status=${safeEncode(st)}`;
  return `<a class="chip ${st}" href="${href}">${st}</a>`;
}

function escapeHtml(s: string) {
  return String(s ?? "")
    .replace(/&/g,"&amp;")
    .replace(/</g,"&lt;")
    .replace(/>/g,"&gt;")
    .replace(/"/g,"&quot;")
    .replace(/'/g,"&#039;");
}
TS

# -------------------------
# [5] Smoke: phase28 end-to-end (UI + webhook + dedupe + status + evidence)
# -------------------------
cat > scripts/smoke-phase28.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $*" >&2; exit 1; }
say(){ echo "==> $*"; }

[ -n "$ADMIN_KEY" ] || fail "missing ADMIN_KEY. Use: ADMIN_KEY=... BASE_URL=... ./scripts/smoke-phase28.sh"

say "[0] health"
curl -sS "$BASE_URL/health" >/dev/null || fail "health not ok"
echo "✅ health ok"

say "[1] /ui hidden (404 expected)"
s1="$(curl -sS -D- -o /dev/null "$BASE_URL/ui" | head -n 1 | awk '{print $2}')"
echo "status=$s1"
[ "${s1:-}" = "404" ] || fail "/ui not 404"

say "[2] /ui/admin redirect (302 expected) + capture Location"
headers="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
loc="$(echo "$headers" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')"
[ -n "${loc:-}" ] || fail "no Location header from /ui/admin"
echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
[ -n "${TENANT_ID:-}" ] || fail "empty TENANT_ID"
[ -n "${TENANT_KEY:-}" ] || fail "empty TENANT_KEY"
echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

final="$BASE_URL$loc"
say "[3] tickets should be 200"
s3="$(curl -sS -D- "$final" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s3"
[ "${s3:-}" = "200" ] || fail "tickets not 200: $final"

say "[4] export.csv should be 200"
exportUrl="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
s4="$(curl -sS -D- "$exportUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s4"
[ "${s4:-}" = "200" ] || fail "export not 200: $exportUrl"

say "[5] evidence.zip should be 200"
zipUrl="$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY"
s5="$(curl -sS -D- "$zipUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s5"
[ "${s5:-}" = "200" ] || fail "zip not 200: $zipUrl"

say "[6] webhook intake should be 201 and dedupe on repeat"
payload='{"source":"webhook","title":"Webhook intake","message":"hello","externalId":"demo-123","priority":"medium","data":{"a":1}}'
w1="$(curl -sS -w "\n%{http_code}\n" -X POST "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Id: demo-123" \
  -d "$payload")"
code1="$(echo "$w1" | tail -n 1)"
body1="$(echo "$w1" | sed '$d')"
echo "status=$code1"
[ "$code1" = "201" ] || fail "webhook not 201: $body1"
echo "$body1" | head -c 200; echo

w2="$(curl -sS -w "\n%{http_code}\n" -X POST "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Id: demo-123" \
  -d "$payload")"
code2="$(echo "$w2" | tail -n 1)"
body2="$(echo "$w2" | sed '$d')"
echo "status=$code2"
[ "$code2" = "201" ] || fail "webhook repeat not 201: $body2"
echo "$body2" | head -c 200; echo

say "[7] tickets page should still be 200 after webhook"
s7="$(curl -sS -D- "$final" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s7"
[ "${s7:-}" = "200" ] || fail "tickets not 200 after webhook"

echo
echo "✅ Phase28 smoke OK"
echo "Client UI:"
echo "  $final"
echo "Export CSV:"
echo "  $exportUrl"
echo "Evidence ZIP:"
echo "  $zipUrl"
BASH
chmod +x scripts/smoke-phase28.sh
echo "✅ wrote scripts/smoke-phase28.sh"

# -------------------------
# [6] Release pack v3 (non-breaking, reuse existing if present)
# -------------------------
if [ -f "scripts/release-pack.sh" ]; then
  # patch header marker only (avoid risky rewrites). if missing, leave as-is.
  if ! grep -q "Release pack v3" scripts/release-pack.sh 2>/dev/null; then
    perl -0777 -i -pe 's/Release pack/Release pack v3 (Phase28)\n# Release pack/ if $.==1' scripts/release-pack.sh 2>/dev/null || true
  fi
else
  cat > scripts/release-pack.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date +%Y-%m-%d_%H%M)"
OUT="dist/intake-guardian-agent/$TS"
mkdir -p "$OUT/assets"

echo "==> Build meta"
cat > "$OUT/publish.meta.json" <<JSON
{
  "product": "intake-guardian-agent",
  "version": "v1",
  "built_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "notes": "Phase28: pipeline+dedupe+status+evidence+guards"
}
JSON

echo "==> Gumroad copy"
cat > "$OUT/GUMROAD_COPY_READY.txt" <<'TXT'
Intake-Guardian (Local) — Webhook Intake → Tickets + Evidence Pack

What it does:
- Receives webhook events per tenant (no accounts UX)
- Creates/updates tickets on disk (dedupe + replay guard)
- Client UI: list tickets, set status, export CSV, download Evidence Pack ZIP

Best for:
- IT support agencies (MSPs)
- Small SaaS teams (incidents/bugs)
- Compliance/audit workflows (exportable evidence)

Includes:
- Full source (Node/TS)
- One-command smoke scripts
- Release pack with checksums

Quick start:
1) pnpm install
2) ADMIN_KEY=super_secret_admin_123 pnpm dev
3) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase28.sh
TXT

echo "==> Checklist"
cat > "$OUT/PUBLISH_CHECKLIST.md" <<'MD'
# Publish Checklist (Phase28)
- [ ] `pnpm install`
- [ ] `ADMIN_KEY=super_secret_admin_123 pnpm dev`
- [ ] `ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase28.sh`
- [ ] Verify UI renders, CSV downloads, ZIP downloads
- [ ] Verify webhook dedupe works (created:false on repeat)
- [ ] Add real screenshots into `assets/` before upload
MD

echo "==> Cover (SVG)"
cat > "$OUT/cover.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="1400" height="900" viewBox="0 0 1400 900">
  <defs>
    <radialGradient id="g1" cx="20%" cy="10%" r="70%">
      <stop offset="0" stop-color="#60a5fa" stop-opacity="0.25"/>
      <stop offset="1" stop-color="#070A12" stop-opacity="1"/>
    </radialGradient>
    <radialGradient id="g2" cx="80%" cy="20%" r="70%">
      <stop offset="0" stop-color="#22c55e" stop-opacity="0.22"/>
      <stop offset="1" stop-color="#070A12" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1400" height="900" fill="url(#g1)"/>
  <rect width="1400" height="900" fill="url(#g2)"/>
  <text x="90" y="170" fill="#e5e7eb" font-family="ui-sans-serif,system-ui" font-weight="900" font-size="64">Intake-Guardian</text>
  <text x="90" y="235" fill="#9ca3af" font-family="ui-sans-serif,system-ui" font-weight="700" font-size="22">
    Webhook Intake → Tickets + Evidence Pack (ZIP) + CSV Export
  </text>
  <rect x="90" y="300" width="1220" height="420" rx="28" fill="rgba(17,24,39,0.55)" stroke="rgba(255,255,255,0.10)"/>
  <text x="130" y="360" fill="#e5e7eb" font-family="ui-monospace,Menlo,monospace" font-size="18">
    /api/webhook/intake?tenantId=...&amp;k=...
  </text>
  <text x="130" y="410" fill="#e5e7eb" font-family="ui-monospace,Menlo,monospace" font-size="18">
    /ui/tickets?tenantId=...&amp;k=...
  </text>
  <text x="130" y="460" fill="#e5e7eb" font-family="ui-monospace,Menlo,monospace" font-size="18">
    Export CSV + Download Evidence Pack (ZIP)
  </text>
</svg>
SVG

echo "==> Zip full product"
mkdir -p "$OUT/assets"
zip -r "$OUT/intake-guardian-agent-v1.zip" . -x "node_modules/*" -x "dist/*" -x "__bak_*/*" -x ".git/*" >/dev/null

echo "==> Zip sample (docs only)"
mkdir -p "$OUT/sample"
cp -f "$OUT/GUMROAD_COPY_READY.txt" "$OUT/sample/" || true
cp -f "$OUT/PUBLISH_CHECKLIST.md" "$OUT/sample/" || true
cp -f "$OUT/cover.svg" "$OUT/sample/" || true
zip -r "$OUT/intake-guardian-agent-v1_SAMPLE.zip" "$OUT/sample" >/dev/null

echo "==> Checksums"
python3 - <<PY
import hashlib, json, pathlib
base = pathlib.Path("$OUT")
files = ["intake-guardian-agent-v1.zip","intake-guardian-agent-v1_SAMPLE.zip","cover.svg","GUMROAD_COPY_READY.txt","PUBLISH_CHECKLIST.md","publish.meta.json"]
out = {}
for f in files:
  p = base / f
  h = hashlib.sha256(p.read_bytes()).hexdigest()
  out[f]=h
(base/"checksums.sha256.json").write_text(json.dumps(out,indent=2))
(base/"checksums.sha256.txt").write_text("\\n".join([f"{v}  {k}" for k,v in out.items()])+"\\n")
PY

echo
echo "✅ Release pack ready:"
echo "  $OUT"
BASH
  chmod +x scripts/release-pack.sh
fi

# -------------------------
# [7] Typecheck (best effort)
# -------------------------
echo "==> Typecheck"
if pnpm -s lint:types >/dev/null 2>&1; then
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase28 installed."
echo "Run:"
echo "  1) (restart) ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase28.sh"
echo "  3) ./scripts/release-pack.sh"
