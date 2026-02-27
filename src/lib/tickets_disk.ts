import fs from "fs/promises";
import path from "path";
import crypto from "crypto";
import type { TicketFlag, TicketStatus } from "./agent_rules.js";

export type TicketRecord = {
  id: string;
  tenantId: string;
  source: string;
  type: string;
  title: string;

  status: TicketStatus;
  flags: TicketFlag[];
  missingFields: string[];

  dedupeKey: string;
  createdAtUtc: string;

  // dedupe telemetry
  lastSeenAtUtc: string;
  duplicateCount: number;

  // raw payload is optional; keep small
  raw?: any;
};

function nowUtc(): string {
  return new Date().toISOString();
}

function randId(prefix = "t_"): string {
  return prefix + crypto.randomBytes(10).toString("hex");
}

async function ensureDir(p: string) {
  await fs.mkdir(p, { recursive: true });
}

function dataDir(): string {
  return process.env.DATA_DIR || "./data";
}

function tenantDir(tenantId: string): string {
  return path.join(dataDir(), "tenants", tenantId);
}

function ticketsFile(tenantId: string): string {
  return path.join(tenantDir(tenantId), "tickets.json");
}

export async function listTickets(tenantId: string): Promise<TicketRecord[]> {
  const file = ticketsFile(tenantId);
  try {
    const s = await fs.readFile(file, "utf8");
    const arr = JSON.parse(s);
    return Array.isArray(arr) ? (arr as TicketRecord[]) : [];
  } catch {
    return [];
  }
}

export async function saveTickets(tenantId: string, tickets: TicketRecord[]): Promise<void> {
  await ensureDir(tenantDir(tenantId));
  const file = ticketsFile(tenantId);

  // stable sort newest first (createdAtUtc)
  tickets.sort((a, b) => (b?.createdAtUtc || "").localeCompare(a?.createdAtUtc || ""));

  await fs.writeFile(file, JSON.stringify(tickets, null, 2) + "\n", "utf8");
}

export type UpsertWebhookArgs = {
  tenantId: string;
  source: string;
  type: string;
  title: string;

  status: TicketStatus;
  flags: TicketFlag[];
  missingFields: string[];

  dedupeKey: string;
  raw?: any;
};

export async function upsertWebhookTicket(args: UpsertWebhookArgs): Promise<{ created: boolean; ticket: TicketRecord }> {
  const tickets = await listTickets(args.tenantId);
  const idx = tickets.findIndex(t => t?.dedupeKey === args.dedupeKey);

  if (idx >= 0) {
    const t = tickets[idx];
    const updated: TicketRecord = {
      ...t,
      // keep first createdAtUtc
      lastSeenAtUtc: nowUtc(),
      duplicateCount: (t.duplicateCount || 0) + 1,
      // do NOT downgrade status; but allow needs_review to persist
      status: t.status === "needs_review" ? t.status : args.status,
      flags: Array.from(new Set([...(t.flags || []), ...(args.flags || [])])),
      missingFields: Array.from(new Set([...(t.missingFields || []), ...(args.missingFields || [])])),
      // update title/source if missing
      title: t.title || args.title,
      source: t.source || args.source,
      type: t.type || args.type,
    };
    tickets[idx] = updated;
    await saveTickets(args.tenantId, tickets);
    return { created: false, ticket: updated };
  }

  const createdAt = nowUtc();
  const ticket: TicketRecord = {
    id: randId(),
    tenantId: args.tenantId,
    source: args.source,
    type: args.type,
    title: args.title,
    status: args.status,
    flags: args.flags || [],
    missingFields: args.missingFields || [],
    dedupeKey: args.dedupeKey,
    createdAtUtc: createdAt,
    lastSeenAtUtc: createdAt,
    duplicateCount: 0,
    raw: args.raw,
  };

  tickets.unshift(ticket);
  await saveTickets(args.tenantId, tickets);
  return { created: true, ticket };
}
