import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";


export function computeEvidenceHash(payload: any): string {
  // compat for legacy evidence-pack
  const crypto = require("node:crypto");
  return crypto.createHash("sha1").update(JSON.stringify(payload ?? {})).digest("hex");
}

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
      let s = String(v ?? "");
      // Prevent formula injection
      if (/^[=+\-@]/.test(s)) {
        s = "'" + s;
      }
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
