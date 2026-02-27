import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type TicketStatus = "open" | "pending" | "closed";

export type TicketEvidence = {
  id: string;
  kind: "note" | "file" | "json";
  title?: string;
  body?: string;
  createdAtUtc: string;
};

export type Ticket = {
  id: string;
  tenantId: string;
  createdAtUtc: string;
  updatedAtUtc: string;
  status: TicketStatus;

  source: "webhook";
  dedupeKey: string;

  // core fields (keep minimal + real)
  title: string;
  requesterEmail?: string;
  requesterName?: string;
  payload: any;

  evidence: TicketEvidence[];
};

function nowUtc() {
  return new Date().toISOString();
}

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function safeJsonParse(s: string) {
  try { return JSON.parse(s); } catch { return null; }
}

function sha256(x: string) {
  return crypto.createHash("sha256").update(x).digest("hex");
}

function randId(prefix: string) {
  return `${prefix}_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
}

function dataDirFromEnv() {
  return process.env.DATA_DIR || "./data";
}

function tenantDir(tenantId: string) {
  const base = path.resolve(dataDirFromEnv());
  return path.join(base, "tenants", tenantId);
}

function ticketsPath(tenantId: string) {
  return path.join(tenantDir(tenantId), "tickets.json");
}

function evidenceDir(tenantId: string) {
  return path.join(tenantDir(tenantId), "evidence");
}

function readTickets(tenantId: string): Ticket[] {
  const p = ticketsPath(tenantId);
  if (!fs.existsSync(p)) return [];
  const raw = fs.readFileSync(p, "utf8");
  const j = safeJsonParse(raw);
  if (!Array.isArray(j)) return [];
  return j as Ticket[];
}

function writeTickets(tenantId: string, tickets: Ticket[]) {
  ensureDir(tenantDir(tenantId));
  fs.writeFileSync(ticketsPath(tenantId), JSON.stringify(tickets, null, 2) + "\n");
}

export function computeDedupeKey(input: {
  tenantId: string;
  email?: string;
  title?: string;
  externalId?: string;
  body?: string;
  rawPayload?: any;
}) {
  // prefer externalId if provided, else stable hash of (email+title+body)
  const base =
    input.externalId
      ? `ext:${input.externalId}`
      : `h:${sha256(JSON.stringify({
          email: (input.email || "").toLowerCase().trim(),
          title: (input.title || "").trim(),
          body: (input.body || "").trim().slice(0, 1200),
          // include small stable projection of payload (optional)
          p: input.rawPayload ? sha256(JSON.stringify(input.rawPayload).slice(0, 4000)) : ""
        }))}`;
  return `${input.tenantId}:${base}`;
}

export function upsertFromWebhook(args: {
  tenantId: string;
  dedupeWindowSeconds: number;
  payload: any;
}) : { created: boolean; ticket: Ticket; deduped: boolean } {
  const { tenantId, dedupeWindowSeconds, payload } = args;

  ensureDir(tenantDir(tenantId));
  ensureDir(evidenceDir(tenantId));

  const email =
    payload?.email || payload?.requester?.email || payload?.from?.email || payload?.contact?.email;
  const name =
    payload?.name || payload?.requester?.name || payload?.from?.name || payload?.contact?.name;

  const title =
    payload?.title ||
    payload?.subject ||
    payload?.summary ||
    "New intake";

  const body =
    payload?.body ||
    payload?.message ||
    payload?.text ||
    payload?.description ||
    "";

  const externalId = payload?.id || payload?.externalId || payload?.eventId;

  const dedupeKey = computeDedupeKey({
    tenantId,
    email,
    title,
    externalId,
    body,
    rawPayload: payload
  });

  const tickets = readTickets(tenantId);

  // find recent ticket with same dedupeKey within window
  const now = Date.now();
  const windowMs = Math.max(1, dedupeWindowSeconds) * 1000;

  const existing = tickets.find(t => {
    if (t.dedupeKey !== dedupeKey) return false;
    const ts = Date.parse(t.createdAtUtc);
    if (!Number.isFinite(ts)) return false;
    return (now - ts) <= windowMs;
  });

  if (existing) {
    // touch updatedAt + attach evidence note of duplicate ping (real proof)
    existing.updatedAtUtc = nowUtc();
    existing.evidence.push({
      id: randId("ev"),
      kind: "note",
      title: "Duplicate intake (deduped)",
      body: "Webhook received again within dedupe window; merged into existing ticket.",
      createdAtUtc: nowUtc(),
    });
    writeTickets(tenantId, tickets);
    return { created: false, ticket: existing, deduped: true };
  }

  const t: Ticket = {
    id: randId("t"),
    tenantId,
    createdAtUtc: nowUtc(),
    updatedAtUtc: nowUtc(),
    status: "open",
    source: "webhook",
    dedupeKey,
    title: String(title || "New intake"),
    requesterEmail: email ? String(email) : undefined,
    requesterName: name ? String(name) : undefined,
    payload,
    evidence: [
      {
        id: randId("ev"),
        kind: "json",
        title: "Raw webhook payload (snapshot)",
        body: JSON.stringify(payload, null, 2),
        createdAtUtc: nowUtc(),
      }
    ]
  };

  tickets.unshift(t);
  writeTickets(tenantId, tickets);

  return { created: true, ticket: t, deduped: false };
}

export function listTickets(tenantId: string): Ticket[] {
  const tickets = readTickets(tenantId);
  // stable sort: newest first
  return tickets.sort((a, b) => String(b.createdAtUtc ?? "").localeCompare(String(a.createdAtUtc ?? "")));
}

export function getTicket(tenantId: string, ticketId: string): Ticket | null {
  const tickets = readTickets(tenantId);
  return tickets.find(t => t.id === ticketId) || null;
}

export function setStatus(tenantId: string, ticketId: string, status: TicketStatus): Ticket | null {
  const tickets = readTickets(tenantId);
  const t = tickets.find(x => x.id === ticketId);
  if (!t) return null;
  t.status = status;
  t.updatedAtUtc = nowUtc();
  t.evidence.push({
    id: randId("ev"),
    kind: "note",
    title: "Status changed",
    body: `Status -> ${status}`,
    createdAtUtc: nowUtc(),
  });
  writeTickets(tenantId, tickets);
  return t;
}

export function addEvidence(tenantId: string, ticketId: string, ev: Omit<TicketEvidence, "id" | "createdAtUtc">): Ticket | null {
  const tickets = readTickets(tenantId);
  const t = tickets.find(x => x.id === ticketId);
  if (!t) return null;
  t.updatedAtUtc = nowUtc();
  t.evidence.push({
    id: randId("ev"),
    createdAtUtc: nowUtc(),
    ...ev,
  });
  writeTickets(tenantId, tickets);
  return t;
}

export function exportCsv(tenantId: string): string {
  const tickets = listTickets(tenantId);
  const esc = (v: any) => {
    const s = String(v ?? "");
    if (/[,"\n]/.test(s)) return `"${s.replace(/"/g,'""')}"`;
    return s;
  };

  const rows = [
    ["ticketId","status","createdAtUtc","updatedAtUtc","title","requesterName","requesterEmail","evidenceCount"].join(",")
  ];

  for (const t of tickets) {
    rows.push([
      esc(t.id),
      esc(t.status),
      esc(t.createdAtUtc),
      esc(t.updatedAtUtc),
      esc(t.title),
      esc(t.requesterName),
      esc(t.requesterEmail),
      esc((t.evidence||[]).length),
    ].join(","));
  }

  return rows.join("\n") + "\n";
}

export function exportJson(tenantId: string) {
  return listTickets(tenantId);
}
