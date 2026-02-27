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
