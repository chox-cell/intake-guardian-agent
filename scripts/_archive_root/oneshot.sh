#!/usr/bin/env bash
set -euo pipefail

# Phase27 guard: always run in repo root
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
[ -d "src" ] || { echo "ERROR: run inside repo root (src missing)"; exit 1; }
[ -d "scripts" ] || { echo "ERROR: run inside repo root (scripts missing)"; exit 1; }

# Make sure target dirs exist (Phase27)
mkdir -p src/lib src/api src/ui scripts dist data >/dev/null 2>&1 || true

say(){ echo "==> $*"; }

set -euo pipefail

# Phase27 OneShot (Ticket Lifecycle + Timeline + Evidence Pack v2 + Webhook security hooks)
# Repo: intake-guardian-agent
# Goal: turn "webhook -> ticket" into a sellable, proof-grade pipeline:
# - ticket lifecycle: open/pending/closed
# - timeline events
# - evidence pack v2 (zip): summary + ticket.json + timeline.json + raw_webhook.json + checksums + README
# - webhook intake dedupe stays
# - UI: badges + status actions + download evidence
# - API: /api/webhook/intake (already), /api/tickets/:id/status, /api/tickets/:id/evidence.zip

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say(){ echo "==> $*"; }

TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase27_${TS}"
say "Phase27 OneShot @ $ROOT"
say "Backup -> $BAK"
mkdir -p "$BAK"
cp -R src scripts tsconfig.json package.json "$BAK/" 2>/dev/null || true

say "Ensure tsconfig excludes backups"
node <<'NODE'
import fs from "node:fs";
const p="tsconfig.json";
if(!fs.existsSync(p)) process.exit(0);
const j=JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.isArray(j.exclude) ? j.exclude : [];
const add = (x)=>{ if(!j.exclude.includes(x)) j.exclude.push(x); };
add("__bak_*");
add("dist");
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
NODE

# -------------------------
# [1] Write tickets pipeline (disk, dedupe, timeline, lifecycle)
# -------------------------
say "Write src/lib/tickets_pipeline.ts"
cat > src/lib/tickets_pipeline.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type TicketStatus = "open" | "pending" | "closed";

export type TimelineEvent =
  | { atUtc: string; type: "webhook_received"; meta?: Record<string, any> }
  | { atUtc: string; type: "dedupe_hit"; meta?: Record<string, any> }
  | { atUtc: string; type: "status_changed"; meta: { from: TicketStatus; to: TicketStatus; note?: string } }
  | { atUtc: string; type: "evidence_exported"; meta?: Record<string, any> };

export type TicketRecord = {
  id: string;
  tenantId: string;
  status: TicketStatus;
  dedupeKey: string;
  createdAtUtc: string;
  updatedAtUtc: string;
  subject?: string;
  source?: string;
};

export type IngestResult = {
  ok: true;
  created: boolean;
  ticket: TicketRecord;
};

function nowUtc() {
  return new Date().toISOString();
}

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function readJson<T>(p: string, fallback: T): T {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8")) as T;
  } catch {
    return fallback;
  }
}

function writeJson(p: string, v: any) {
  ensureDir(path.dirname(p));
  fs.writeFileSync(p, JSON.stringify(v, null, 2) + "\n");
}

function sha1(input: string) {
  return crypto.createHash("sha1").update(input).digest("hex");
}

function randId(prefix: string) {
  return `${prefix}_${crypto.randomBytes(10).toString("hex")}`;
}

function safeJsonStringify(x: any) {
  try {
    return JSON.stringify(x);
  } catch {
    return JSON.stringify({ _unserializable: true });
  }
}

export function tenantDir(dataDir: string, tenantId: string) {
  return path.join(dataDir, "tenants", tenantId);
}

export function ticketsDir(dataDir: string, tenantId: string) {
  return path.join(tenantDir(dataDir, tenantId), "tickets");
}

export function ticketDir(dataDir: string, tenantId: string, ticketId: string) {
  return path.join(ticketsDir(dataDir, tenantId), ticketId);
}

export function ticketPath(dataDir: string, tenantId: string, ticketId: string) {
  return path.join(ticketDir(dataDir, tenantId, ticketId), "ticket.json");
}

export function timelinePath(dataDir: string, tenantId: string, ticketId: string) {
  return path.join(ticketDir(dataDir, tenantId, ticketId), "timeline.json");
}

export function rawWebhookPath(dataDir: string, tenantId: string, ticketId: string) {
  return path.join(ticketDir(dataDir, tenantId, ticketId), "raw_webhook.json");
}

function dedupeIndexPath(dataDir: string, tenantId: string) {
  return path.join(tenantDir(dataDir, tenantId), "dedupe_index.json");
}

type DedupeIndex = Record<
  string,
  { ticketId: string; atUtc: string }
>;

function dedupeKeyFromPayload(payload: any) {
  // stable-ish key: hash canonical json string (best effort)
  const s = safeJsonStringify(payload);
  return sha1(s);
}

export function listTickets(dataDir: string, tenantId: string): TicketRecord[] {
  const dir = ticketsDir(dataDir, tenantId);
  if (!fs.existsSync(dir)) return [];
  const ids = fs
    .readdirSync(dir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);

  const out: TicketRecord[] = [];
  for (const id of ids) {
    const p = ticketPath(dataDir, tenantId, id);
    if (!fs.existsSync(p)) continue;
    const t = readJson<TicketRecord | null>(p, null);
    if (t) out.push(t);
  }
  // newest first
  out.sort((a, b) => (b.updatedAtUtc || b.createdAtUtc).localeCompare(a.updatedAtUtc || a.createdAtUtc));
  return out;
}

export function getTicket(dataDir: string, tenantId: string, ticketId: string): TicketRecord | null {
  const p = ticketPath(dataDir, tenantId, ticketId);
  if (!fs.existsSync(p)) return null;
  return readJson<TicketRecord | null>(p, null);
}

export function getTimeline(dataDir: string, tenantId: string, ticketId: string): TimelineEvent[] {
  const p = timelinePath(dataDir, tenantId, ticketId);
  return readJson<TimelineEvent[]>(p, []);
}

export function appendTimeline(dataDir: string, tenantId: string, ticketId: string, ev: TimelineEvent) {
  const p = timelinePath(dataDir, tenantId, ticketId);
  const arr = readJson<TimelineEvent[]>(p, []);
  arr.push(ev);
  writeJson(p, arr);
}

export function ingestWebhook(params: {
  dataDir: string;
  tenantId: string;
  payload: any;
  headers?: Record<string, any>;
  source?: string;
  subject?: string;
  dedupeWindowSeconds: number;
}): IngestResult {
  const { dataDir, tenantId, payload, headers, source, subject, dedupeWindowSeconds } = params;

  const dk = dedupeKeyFromPayload(payload);
  const idxPath = dedupeIndexPath(dataDir, tenantId);
  const idx = readJson<DedupeIndex>(idxPath, {});

  // purge old
  const now = Date.now();
  const windowMs = Math.max(1, dedupeWindowSeconds) * 1000;
  for (const k of Object.keys(idx)) {
    const t = Date.parse(idx[k].atUtc);
    if (!Number.isFinite(t) || now - t > windowMs) delete idx[k];
  }

  // dedupe hit
  const hit = idx[dk];
  if (hit && hit.ticketId) {
    const existing = getTicket(dataDir, tenantId, hit.ticketId);
    if (existing) {
      appendTimeline(dataDir, tenantId, existing.id, { atUtc: nowUtc(), type: "dedupe_hit", meta: { dedupeKey: dk } });
      writeJson(idxPath, idx);
      return { ok: true, created: false, ticket: existing };
    }
  }

  // create new ticket
  const id = randId("t");
  const createdAtUtc = nowUtc();
  const t: TicketRecord = {
    id,
    tenantId,
    status: "open",
    dedupeKey: dk,
    createdAtUtc,
    updatedAtUtc: createdAtUtc,
    source,
    subject,
  };

  writeJson(ticketPath(dataDir, tenantId, id), t);
  writeJson(rawWebhookPath(dataDir, tenantId, id), {
    receivedAtUtc: createdAtUtc,
    headers: headers || {},
    payload,
  });
  writeJson(timelinePath(dataDir, tenantId, id), []);
  appendTimeline(dataDir, tenantId, id, { atUtc: createdAtUtc, type: "webhook_received", meta: { source: source || "webhook" } });

  // store in dedupe index
  idx[dk] = { ticketId: id, atUtc: createdAtUtc };
  writeJson(idxPath, idx);

  return { ok: true, created: true, ticket: t };
}

export function setTicketStatus(params: {
  dataDir: string;
  tenantId: string;
  ticketId: string;
  to: TicketStatus;
  note?: string;
}): { ok: true; ticket: TicketRecord } | { ok: false; error: string } {
  const { dataDir, tenantId, ticketId, to, note } = params;
  const t = getTicket(dataDir, tenantId, ticketId);
  if (!t) return { ok: false, error: "not_found" };
  const from = t.status;
  if (from === to) return { ok: true, ticket: t };

  const updated: TicketRecord = { ...t, status: to, updatedAtUtc: nowUtc() };
  writeJson(ticketPath(dataDir, tenantId, ticketId), updated);
  appendTimeline(dataDir, tenantId, ticketId, { atUtc: nowUtc(), type: "status_changed", meta: { from, to, note } });
  return { ok: true, ticket: updated };
}

export function buildEvidencePackV2(params: {
  dataDir: string;
  tenantId: string;
  ticketId: string;
}): { ok: true; dir: string; files: string[] } | { ok: false; error: string } {
  const { dataDir, tenantId, ticketId } = params;
  const t = getTicket(dataDir, tenantId, ticketId);
  if (!t) return { ok: false, error: "not_found" };

  const dir = path.join(ticketDir(dataDir, tenantId, ticketId), "evidence_v2");
  ensureDir(dir);

  const tl = getTimeline(dataDir, tenantId, ticketId);
  const raw = readJson<any>(rawWebhookPath(dataDir, tenantId, ticketId), {});

  const summary = {
    product: "Intake-Guardian",
    version: "evidence_v2",
    generatedAtUtc: nowUtc(),
    tenantId,
    ticketId,
    status: t.status,
    createdAtUtc: t.createdAtUtc,
    updatedAtUtc: t.updatedAtUtc,
    dedupeKey: t.dedupeKey,
  };

  const readme = [
    "Intake-Guardian — Evidence Pack (v2)",
    "",
    "This package provides proof-grade artifacts for a single intake ticket.",
    "Contents:",
    " - summary.json: human-readable metadata",
    " - ticket.json: current ticket state",
    " - timeline.json: immutable event history",
    " - raw_webhook.json: original inbound payload + headers (as received)",
    " - checksums.sha256: file integrity hashes",
    "",
    "Notes:",
    " - The system may deduplicate identical webhook payloads within a time window.",
    " - This evidence pack is designed for sharing with clients, auditors, or internal QA.",
    "",
  ].join("\n");

  const f_summary = path.join(dir, "summary.json");
  const f_ticket = path.join(dir, "ticket.json");
  const f_timeline = path.join(dir, "timeline.json");
  const f_raw = path.join(dir, "raw_webhook.json");
  const f_readme = path.join(dir, "README.txt");
  const f_checks = path.join(dir, "checksums.sha256");

  writeJson(f_summary, summary);
  writeJson(f_ticket, t);
  writeJson(f_timeline, tl);
  writeJson(f_raw, raw);
  fs.writeFileSync(f_readme, readme);

  // sha256 checksums
  const files = [f_summary, f_ticket, f_timeline, f_raw, f_readme];
  const lines: string[] = [];
  for (const fp of files) {
    const b = fs.readFileSync(fp);
    const h = crypto.createHash("sha256").update(b).digest("hex");
    lines.push(`${h}  ${path.basename(fp)}`);
  }
  fs.writeFileSync(f_checks, lines.join("\n") + "\n");

  appendTimeline(dataDir, tenantId, ticketId, { atUtc: nowUtc(), type: "evidence_exported", meta: { pack: "v2" } });

  return { ok: true, dir, files: [...files, f_checks].map((x) => path.basename(x)) };
}
TS

# -------------------------
# [2] Webhook route: real intake + optional signature hooks (non-breaking)
# -------------------------
say "Write src/api/webhook.ts"
cat > src/api/webhook.ts <<'TS'
import type { Express } from "express";
import crypto from "node:crypto";

import { verifyTenantKeyLocal } from "../lib/tenant_registry.js";
import { ingestWebhook } from "../lib/tickets_pipeline.js";

function jsonBody(req: any) {
  // express.json middleware should already parse it; fallback:
  return (req && req.body) ?? {};
}

function getTenantId(req: any): string {
  return (req.query?.tenantId || req.body?.tenantId || req.headers?.["x-tenant-id"] || "").toString();
}

function getTenantKey(req: any): string {
  const q = (req.query?.k || req.query?.key || "").toString();
  const h = (req.headers?.["x-tenant-key"] || "").toString();
  const b = (req.body?.tenantKey || req.body?.k || "").toString();
  return q || h || b;
}

function safeHeaders(req: any) {
  const out: Record<string, any> = {};
  for (const [k, v] of Object.entries(req.headers || {})) {
    if (typeof v === "string") out[k] = v;
  }
  return out;
}

/**
 * Optional webhook signature verification:
 * - If WEBHOOK_SIGNING_SECRET is set, require:
 *   headers: x-ig-timestamp (unix seconds) and x-ig-signature (hex hmac sha256)
 *   signature = hmac(secret, `${ts}.${rawBodyString}`)
 *
 * If not set => accept (keeps dev easy)
 */
function verifyWebhookSigIfEnabled(req: any, rawBodyString: string): { ok: true } | { ok: false; error: string } {
  const secret = process.env.WEBHOOK_SIGNING_SECRET || "";
  if (!secret) return { ok: true };

  const ts = (req.headers?.["x-ig-timestamp"] || "").toString();
  const sig = (req.headers?.["x-ig-signature"] || "").toString();
  if (!ts || !sig) return { ok: false, error: "missing_signature_headers" };

  const now = Math.floor(Date.now() / 1000);
  const n = Number(ts);
  if (!Number.isFinite(n)) return { ok: false, error: "bad_timestamp" };
  const skew = Math.abs(now - n);
  const maxSkew = Number(process.env.WEBHOOK_MAX_SKEW_SECONDS || "300");
  if (skew > maxSkew) return { ok: false, error: "timestamp_out_of_window" };

  const mac = crypto.createHmac("sha256", secret).update(`${ts}.${rawBodyString}`).digest("hex");
  const a = Buffer.from(mac);
  const b = Buffer.from(sig);
  if (a.length !== b.length) return { ok: false, error: "bad_signature" };
  if (!crypto.timingSafeEqual(a, b)) return { ok: false, error: "bad_signature" };

  return { ok: true };
}

export function mountWebhook(app: Express, args?: { dataDir?: string; dedupeWindowSeconds?: number }) {
  const dataDir = (args?.dataDir || process.env.DATA_DIR || "./data").toString();
  const dedupeWindowSeconds = Number(args?.dedupeWindowSeconds ?? process.env.DEDUPE_WINDOW_SECONDS ?? "86400");

  // IMPORTANT: we keep the same endpoint: POST /api/webhook/intake
  app.post("/api/webhook/intake", (req, res) => {
    const tenantId = getTenantId(req);
    const tenantKey = getTenantKey(req);

    if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });
    if (!tenantKey) return res.status(401).json({ ok: false, error: "missing_tenant_key" });

    // tenant key gate (local SSOT registry)
    const ok = verifyTenantKeyLocal(tenantId, tenantKey);
    if (!ok) return res.status(401).json({ ok: false, error: "invalid_tenant_key" });

    // signature (optional)
    const body = jsonBody(req);
    const rawStr = (() => {
      try { return JSON.stringify(body); } catch { return "{}"; }
    })();
    const sig = verifyWebhookSigIfEnabled(req, rawStr);
    if (!sig.ok) return res.status(401).json({ ok: false, error: sig.error });

    const r = ingestWebhook({
      dataDir,
      tenantId,
      payload: body,
      headers: safeHeaders(req),
      source: (req.headers?.["user-agent"] || "webhook").toString(),
      subject: (body && (body.subject || body.title || body.name)) ? String(body.subject || body.title || body.name) : undefined,
      dedupeWindowSeconds: Number.isFinite(dedupeWindowSeconds) ? dedupeWindowSeconds : 86400,
    });

    return res.status(201).json(r);
  });
}
TS

# -------------------------
# [3] Tickets API: status + evidence zip
# -------------------------
say "Write src/api/tickets.ts"
cat > src/api/tickets.ts <<'TS'
import type { Express } from "express";
import path from "node:path";
import fs from "node:fs";
import { spawnSync } from "node:child_process";

import { verifyTenantKeyLocal } from "../lib/tenant_registry.js";
import { setTicketStatus, buildEvidencePackV2, getTicket } from "../lib/tickets_pipeline.js";

function getTenantId(req: any): string {
  return (req.query?.tenantId || req.body?.tenantId || req.headers?.["x-tenant-id"] || "").toString();
}
function getTenantKey(req: any): string {
  const q = (req.query?.k || req.query?.key || "").toString();
  const h = (req.headers?.["x-tenant-key"] || "").toString();
  const b = (req.body?.tenantKey || req.body?.k || "").toString();
  return q || h || b;
}

export function mountTicketsApi(app: Express, args?: { dataDir?: string }) {
  const dataDir = (args?.dataDir || process.env.DATA_DIR || "./data").toString();

  // POST /api/tickets/:id/status  body: { to: "open"|"pending"|"closed", note? }
  app.post("/api/tickets/:id/status", (req, res) => {
    const tenantId = getTenantId(req);
    const tenantKey = getTenantKey(req);
    if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });
    if (!tenantKey) return res.status(401).json({ ok: false, error: "missing_tenant_key" });
    if (!verifyTenantKeyLocal(tenantId, tenantKey)) return res.status(401).json({ ok: false, error: "invalid_tenant_key" });

    const id = String(req.params.id || "");
    const to = String(req.body?.to || "");
    const note = req.body?.note ? String(req.body.note) : undefined;

    if (!id) return res.status(400).json({ ok: false, error: "missing_ticket_id" });
    if (!["open", "pending", "closed"].includes(to)) return res.status(400).json({ ok: false, error: "bad_status" });

    const r = setTicketStatus({ dataDir, tenantId, ticketId: id, to: to as any, note });
    if (!r.ok) return res.status(404).json({ ok: false, error: r.error });
    return res.json({ ok: true, ticket: r.ticket });
  });

  // GET /api/tickets/:id/evidence.zip?tenantId=...&k=...
  app.get("/api/tickets/:id/evidence.zip", (req, res) => {
    const tenantId = getTenantId(req);
    const tenantKey = getTenantKey(req);
    if (!tenantId) return res.status(400).send("missing_tenantId");
    if (!tenantKey) return res.status(401).send("missing_tenant_key");
    if (!verifyTenantKeyLocal(tenantId, tenantKey)) return res.status(401).send("invalid_tenant_key");

    const id = String(req.params.id || "");
    if (!id) return res.status(400).send("missing_ticket_id");
    const t = getTicket(dataDir, tenantId, id);
    if (!t) return res.status(404).send("not_found");

    const built = buildEvidencePackV2({ dataDir, tenantId, ticketId: id });
    if (!built.ok) return res.status(404).send(built.error);

    // Create zip on the fly using system 'zip' (mac/linux)
    // Zip file stored next to evidence dir
    const evidenceDir = built.dir;
    const zipPath = path.join(evidenceDir, `evidence_${id}.zip`);

    try {
      if (fs.existsSync(zipPath)) fs.unlinkSync(zipPath);
    } catch {}

    // zip -r evidence_x.zip .
    const r = spawnSync("zip", ["-r", path.basename(zipPath), "."], {
      cwd: evidenceDir,
      encoding: "utf8",
    });

    if (r.status !== 0 || !fs.existsSync(zipPath)) {
      const err = (r.stderr || r.stdout || "zip_failed").toString();
      return res.status(500).send(err.slice(0, 4000));
    }

    res.setHeader("Content-Type", "application/zip");
    res.setHeader("Content-Disposition", `attachment; filename="evidence_${id}.zip"`);
    fs.createReadStream(zipPath).pipe(res);
  });
}
TS

# -------------------------
# [4] UI: show lifecycle + actions + evidence download
# -------------------------
say "Write src/ui/routes.ts (Phase27 business UI)"
cat > src/ui/routes.ts <<'TS'
import type { Express } from "express";
import { verifyTenantKeyLocal, getOrCreateDemoTenant } from "../lib/tenant_registry.js";
import { listTickets } from "../lib/tickets_pipeline.js";

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function getTenantId(req: any) {
  return (req.query?.tenantId || "").toString();
}
function getTenantKey(req: any) {
  return (req.query?.k || "").toString();
}

function okGate(req: any) {
  const tenantId = getTenantId(req);
  const k = getTenantKey(req);
  if (!tenantId || !k) return { ok: false as const, status: 401, error: "missing_tenant_key" };
  if (!verifyTenantKeyLocal(tenantId, k)) return { ok: false as const, status: 401, error: "invalid_tenant_key" };
  return { ok: true as const, tenantId, k };
}

function uiShell(title: string, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${esc(title)}</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial; background: radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%); color:#e5e7eb; }
  .wrap { max-width: 1180px; margin: 56px auto; padding: 0 18px; }
  .card { border:1px solid rgba(255,255,255,.08); background: rgba(17,24,39,.55); border-radius: 18px; padding: 18px 18px; box-shadow: 0 18px 60px rgba(0,0,0,.35); }
  .h { font-size: 24px; font-weight: 850; margin: 0 0 10px; letter-spacing: .2px; }
  .muted { color: #9ca3af; font-size: 13px; }
  .row { display:flex; gap:10px; flex-wrap:wrap; align-items:center; }
  .btn { display:inline-block; padding:10px 14px; border-radius: 12px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.25); color:#e5e7eb; text-decoration:none; font-weight:700; cursor:pointer; }
  .btn:hover { border-color: rgba(255,255,255,.18); background: rgba(0,0,0,.34); }
  .btn.primary { background: rgba(34,197,94,.16); border-color: rgba(34,197,94,.30); }
  .btn.warn { background: rgba(245,158,11,.14); border-color: rgba(245,158,11,.28); }
  .btn.danger { background: rgba(239,68,68,.12); border-color: rgba(239,68,68,.22); }
  table { width:100%; border-collapse: collapse; margin-top: 12px; }
  th, td { text-align:left; padding: 10px 10px; border-bottom: 1px solid rgba(255,255,255,.06); font-size: 13px; vertical-align: top; }
  th { color:#9ca3af; font-weight: 800; font-size: 12px; letter-spacing: .08em; text-transform: uppercase; }
  .chip { display:inline-block; padding: 4px 10px; border-radius: 999px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.20); font-weight: 800; font-size: 12px; }
  .chip.open { border-color: rgba(59,130,246,.35); background: rgba(59,130,246,.12); }
  .chip.pending { border-color: rgba(245,158,11,.35); background: rgba(245,158,11,.12); }
  .chip.closed { border-color: rgba(34,197,94,.35); background: rgba(34,197,94,.12); }
  .kbd { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; font-size: 12px; padding: 3px 8px; border-radius: 10px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.30); color:#e5e7eb; }
  pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
  .tiny { font-size: 12px; color:#9ca3af; }
</style>
</head>
<body>
  <div class="wrap">
    ${body}
  </div>
</body>
</html>`;
}

async function adminAutolink(req: any, res: any) {
  const admin = (req.query?.admin || "").toString();
  const expected = (process.env.ADMIN_KEY || "").toString();
  if (!expected || admin !== expected) {
    return res.status(401).send(uiShell("Admin error", `<div class="card"><div class="h">Admin error</div><div class="muted">bad_admin_key</div></div>`));
  }
  const tenant = await getOrCreateDemoTenant(process.env.DATA_DIR || "./data");
  const loc = `/ui/tickets?tenantId=${encodeURIComponent(tenant.tenantId)}&k=${encodeURIComponent(tenant.tenantKey)}`;
  res.setHeader("Location", loc);
  return res.status(302).end();
}

function renderTicketsPage(params: { tenantId: string; k: string; dataDir: string }) {
  const { tenantId, k, dataDir } = params;
  const tickets = listTickets(dataDir, tenantId);

  const rows = tickets
    .map((t) => {
      const chip = `<span class="chip ${t.status}">${esc(t.status)}</span>`;
      const evidence = `/api/tickets/${encodeURIComponent(t.id)}/evidence.zip?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
      const exportCsv = `/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
      const statusApi = `/api/tickets/${encodeURIComponent(t.id)}/status?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
      return `<tr>
<td style="width:190px">
  <div style="font-weight:850">${esc(t.id)}</div>
  <div class="tiny">${esc(t.createdAtUtc)}</div>
</td>
<td style="width:110px">${chip}</td>
<td>
  <div><span class="tiny">dedupe:</span> <span class="kbd">${esc(t.dedupeKey.slice(0,12))}</span></div>
  ${t.subject ? `<div style="margin-top:6px">${esc(t.subject)}</div>` : ``}
</td>
<td style="width:340px">
  <div class="row">
    <button class="btn primary" onclick="setStatus('${esc(t.id)}','open')">Open</button>
    <button class="btn warn" onclick="setStatus('${esc(t.id)}','pending')">Pending</button>
    <button class="btn danger" onclick="setStatus('${esc(t.id)}','closed')">Closed</button>
    <a class="btn" href="${esc(evidence)}">Evidence ZIP</a>
  </div>
  <div class="tiny" style="margin-top:8px">Export all: <a href="${esc(exportCsv)}" style="color:#93c5fd">${esc(exportCsv)}</a></div>
  <div class="tiny">Status API: <span class="kbd">${esc(statusApi)}</span></div>
</td>
</tr>`;
    })
    .join("\n");

  const body = `
<div class="card">
  <div class="h">Tickets</div>
  <div class="muted">Proof-grade intake: webhook → ticket → lifecycle → evidence</div>
  <div class="row" style="margin-top:10px">
    <span class="kbd">tenantId=${esc(tenantId)}</span>
    <span class="kbd">k=${esc(k)}</span>
    <a class="btn" href="/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}">Export CSV</a>
  </div>

  <table>
    <thead><tr><th>Ticket</th><th>Status</th><th>Details</th><th>Actions</th></tr></thead>
    <tbody>${rows || `<tr><td colspan="4" class="muted">No tickets yet. Send a webhook to create one.</td></tr>`}</tbody>
  </table>

  <div class="muted" style="margin-top:12px">Intake-Guardian • ${esc(new Date().toISOString())}</div>
</div>

<script>
async function setStatus(id,to){
  try{
    const note = prompt("Optional note for timeline (leave empty ok):") || "";
    const url = "/api/tickets/"+encodeURIComponent(id)+"/status?tenantId="+encodeURIComponent("${esc(tenantId)}")+"&k="+encodeURIComponent("${esc(k)}");
    const r = await fetch(url,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({to,note})});
    if(!r.ok){ alert("Status update failed: "+r.status); return; }
    location.reload();
  }catch(e){
    alert("Error: "+(e && e.message ? e.message : e));
  }
}
</script>
`;
  return uiShell("Tickets", body);
}

export function mountUi(app: Express) {
  const dataDir = (process.env.DATA_DIR || "./data").toString();

  // Hide root UI
  app.get("/ui", (_req, res) => res.status(404).send("not_found"));

  // Admin autolink (creates/returns demo tenant and redirects with k)
  app.get("/ui/admin", adminAutolink);

  // Client tickets view (requires tenant key)
  app.get("/ui/tickets", (req, res) => {
    const g = okGate(req);
    if (!g.ok) return res.status(g.status).send(uiShell("Auth error", `<div class="card"><div class="h">Auth error</div><div class="muted">${esc(g.error)}</div></div>`));
    return res.status(200).send(renderTicketsPage({ tenantId: g.tenantId, k: g.k, dataDir }));
  });

  // CSV export for tenant (requires tenant key)
  app.get("/ui/export.csv", (req, res) => {
    const g = okGate(req);
    if (!g.ok) return res.status(g.status).send(g.error);

    const rows = listTickets(dataDir, g.tenantId);
    const header = ["id", "status", "dedupeKey", "createdAtUtc", "updatedAtUtc", "subject"].join(",");
    const lines = rows.map((t) => {
      const q = (x: any) => `"${String(x ?? "").replaceAll('"', '""')}"`;
      return [q(t.id), q(t.status), q(t.dedupeKey), q(t.createdAtUtc), q(t.updatedAtUtc), q(t.subject || "")].join(",");
    });
    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.status(200).send([header, ...lines].join("\n") + "\n");
  });
}
TS

# -------------------------
# [5] Patch server to mount tickets api (non-breaking)
# -------------------------
say "Patch src/server.ts to mountTicketsApi (safe insert)"
node <<'NODE'
import fs from "node:fs";

const p="src/server.ts";
if(!fs.existsSync(p)) {
  console.log("WARN: src/server.ts not found, skipping patch");
  process.exit(0);
}
let s = fs.readFileSync(p,"utf8");

// Ensure imports
if(!s.includes('from "./api/tickets.js"')) {
  s = s.replace(
    /from "\.\/api\/webhook\.js";\n/,
    m => m + 'import { mountTicketsApi } from "./api/tickets.js";\n'
  );
}

// Ensure mount call near mountWebhook/mountUi
if(!s.includes("mountTicketsApi(")) {
  // Try to insert after mountWebhook(...)
  s = s.replace(
    /mountWebhook\(([^)]*)\);\n/,
    (m) => m + '  mountTicketsApi(app as any, { dataDir: process.env.DATA_DIR || "./data" });\n'
  );
}

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mountTicketsApi)");
NODE

# -------------------------
# [6] Scripts: smoke phase27 (ui + webhook + status + evidence)
# -------------------------
say "Write scripts/smoke-phase27.sh"
cat > scripts/smoke-phase27.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "❌ $*"; exit 1; }

echo "==> [0] health"
s0="$(curl -sS -D- "$BASE_URL/health" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${s0:-}" = "200" ] || fail "health not 200"
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -D- "$BASE_URL/ui" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${s1:-}" = "404" ] || fail "/ui not hidden"
echo "✅ /ui hidden"

echo "==> [2] /ui/admin redirect (302 expected)"
[ -n "${ADMIN_KEY:-}" ] || fail "missing ADMIN_KEY env"
hdr="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
s2="$(echo "$hdr" | head -n 1 | awk '{print $2}')"
[ "${s2:-}" = "302" ] || fail "/ui/admin not 302"
loc="$(echo "$hdr" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')"
[ -n "$loc" ] || fail "no Location header"
echo "✅ Location: $loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
[ -n "$TENANT_ID" ] || fail "TENANT_ID empty"
[ -n "$TENANT_KEY" ] || fail "TENANT_KEY empty"
echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

echo "==> [3] tickets page 200"
s3="$(curl -sS -D- "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${s3:-}" = "200" ] || fail "tickets not 200"
echo "✅ tickets ok"

echo "==> [4] webhook intake 201"
payload='{"subject":"Phase27 test","email":"test@example.com","message":"hello from smoke-phase27","ts":"'$(date -u +%FT%TZ)'"}'
s4="$(curl -sS -D- -o /tmp/_ig_webhook.json \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: $TENANT_ID" \
  -H "X-Tenant-Key: $TENANT_KEY" \
  -X POST "$BASE_URL/api/webhook/intake" \
  --data "$payload" | head -n 1 | awk '{print $2}')"
[ "${s4:-}" = "201" ] || fail "webhook not 201"
echo "✅ webhook ok"
cat /tmp/_ig_webhook.json || true

ticketId="$(node -e 'try{const j=require("fs").readFileSync("/tmp/_ig_webhook.json","utf8");const o=JSON.parse(j);process.stdout.write(o.ticket && o.ticket.id ? o.ticket.id : "");}catch(e){process.stdout.write("");}')"
[ -n "$ticketId" ] || fail "could not parse ticket id"
echo "ticketId=$ticketId"

echo "==> [5] status change -> pending (200)"
s5="$(curl -sS -D- -o /dev/null \
  -H "Content-Type: application/json" \
  -X POST "$BASE_URL/api/tickets/$ticketId/status?tenantId=$TENANT_ID&k=$TENANT_KEY" \
  --data '{"to":"pending","note":"smoke-phase27 pending"}' | head -n 1 | awk '{print $2}')"
[ "${s5:-}" = "200" ] || fail "status pending not 200"
echo "✅ status pending ok"

echo "==> [6] evidence zip (200)"
s6="$(curl -sS -D- -o /dev/null \
  "$BASE_URL/api/tickets/$ticketId/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY" | head -n 1 | awk '{print $2}')"
[ "${s6:-}" = "200" ] || fail "evidence zip not 200"
echo "✅ evidence zip ok"

echo "✅ Phase27 smoke ok"
echo "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
echo "$BASE_URL/api/tickets/$ticketId/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY"
BASH
chmod +x scripts/smoke-phase27.sh
say "✅ wrote scripts/smoke-phase27.sh"

# -------------------------
# [7] Typecheck
# -------------------------
say "Typecheck"
if pnpm -s lint:types >/dev/null 2>&1; then
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase27 installed."
echo "Now:"
echo "  1) restart:  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) smoke:    ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase27.sh"
echo
echo "Key UI:"
echo "  http://127.0.0.1:7090/ui/admin?admin=super_secret_admin_123"
