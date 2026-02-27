import fs from "node:fs";
import fsProm from "node:fs/promises";
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

// Cache structure: tenantId -> { mtime: number, tickets: Ticket[] }
const ticketCache = new Map<string, { mtime: number, tickets: Ticket[] }>();

// Simple in-memory mutex per tenant to prevent concurrent write races
const tenantLocks = new Map<string, Promise<void>>();

function withTenantLock<T>(tenantId: string, fn: () => Promise<T>): Promise<T> {
  // Get the current lock promise for this tenant, or start with resolved
  let currentLock = tenantLocks.get(tenantId) || Promise.resolve();

  // Create a new lock promise that chains onto the previous one
  const nextLock = currentLock.then(() => fn()).finally(() => {
    // Cleanup logic: if the map still points to this specific promise, and it's done,
    // we could remove it. But standard Promise chaining is safe enough.
    // If we wanted to aggressively clean map:
    // if (tenantLocks.get(tenantId) === nextLock) { tenantLocks.delete(tenantId); }
    // But that's risky if next request comes in concurrently.
    // Let's rely on standard GC of resolved promises.
  });

  // Update the map to point to the new tail of the queue
  // We attach a catch handler to the stored promise so the chain doesn't break on error,
  // allowing subsequent operations to proceed.
  tenantLocks.set(tenantId, nextLock.catch(() => {}));

  return nextLock;
}


function ensureDir(p: string) {
  // Sync ensureDir is fine for initial setup or infrequent ops
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

// Optimized Async Loader with Caching
async function loadTicketsAsync(tenantId: string): Promise<Ticket[]> {
  const fp = ticketsPath(tenantId);

  try {
    const stats = await fsProm.stat(fp);
    const mtime = stats.mtimeMs;

    const cached = ticketCache.get(tenantId);
    if (cached && cached.mtime === mtime) {
      // return a copy to avoid mutation of cached data by consumers
      return cached.tickets.slice();
    }

    const raw = await fsProm.readFile(fp, "utf8");
    const j = JSON.parse(raw);
    const tickets = Array.isArray(j) ? (j as Ticket[]) : [];

    ticketCache.set(tenantId, { mtime, tickets });
    return tickets.slice();

  } catch (err: any) {
    if (err.code === 'ENOENT') {
      return [];
    }
    return [];
  }
}

// Optimized Async Saver
async function saveTicketsAsync(tenantId: string, rows: Ticket[]) {
  const dir = tenantDir(tenantId);
  if (!fs.existsSync(dir)) {
    await fsProm.mkdir(dir, { recursive: true });
  }

  const fp = ticketsPath(tenantId);
  const data = JSON.stringify(rows, null, 2);

  await fsProm.writeFile(fp, data, "utf8");

  const stats = await fsProm.stat(fp);
  ticketCache.set(tenantId, { mtime: stats.mtimeMs, tickets: rows });
}


function sha1(v: string) {
  return crypto.createHash("sha1").update(v).digest("hex");
}
function sha256(v: string) {
  return crypto.createHash("sha256").update(v).digest("hex");
}

export async function listTickets(tenantId: string): Promise<Ticket[]> {
  const tickets = await loadTicketsAsync(tenantId);
  return tickets.sort((a, b) => (a.createdAtUtc < b.createdAtUtc ? 1 : -1));
}

export async function setTicketStatus(tenantId: string, ticketId: string, status: TicketStatus): Promise<{ ok: boolean }> {
  return withTenantLock(tenantId, async () => {
    const rows = await loadTicketsAsync(tenantId);
    const t = rows.find(x => x.id === ticketId);
    if (!t) return { ok: false };
    t.status = status;
    t.lastSeenAtUtc = new Date().toISOString();
    await saveTicketsAsync(tenantId, rows);
    return { ok: true };
  });
}

/**
 * Upsert with dedupe:
 * - dedupeKey computed from payload (stable)
 * - if exists: bump duplicateCount + lastSeenAtUtc
 */
export async function upsertTicket(
  tenantId: string,
  input: {
    source?: string;
    type?: string;
    title?: string;
    payload?: any;
    missingFields?: string[];
    flags?: string[];
  }
): Promise<{ ticket: Ticket; created: boolean }> {
  return withTenantLock(tenantId, async () => {
    const now = new Date().toISOString();
    const rows = await loadTicketsAsync(tenantId);

    const payload = input.payload ?? {};
    const dedupeKey = sha1(JSON.stringify(payload));

    let t = rows.find(r => r.evidenceHash === dedupeKey);
    if (t) {
      t.duplicateCount = (t.duplicateCount || 0) + 1;
      t.lastSeenAtUtc = now;
      await saveTicketsAsync(tenantId, rows);
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
    await saveTicketsAsync(tenantId, rows);
    return { ticket: t, created: true };
  });
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
