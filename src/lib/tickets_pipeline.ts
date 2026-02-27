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
