import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type DemoTicket = {
  id: string;
  createdAt: string;
  subject: string;
  sender: string;
  status: "open" | "triage" | "closed";
  priority: "low" | "medium" | "high";
  due?: string;
};

function nowISO() { return new Date().toISOString(); }
function dataDir() { return path.resolve(process.env.DATA_DIR ?? "./data"); }

function fileFor(tenantId: string) {
  return path.join(dataDir(), "demo_tickets", `${tenantId}.json`);
}

export function listDemoTickets(tenantId: string): DemoTicket[] {
  const p = fileFor(tenantId);
  try {
    const raw = fs.readFileSync(p, "utf8");
    const j = JSON.parse(raw);
    return Array.isArray(j) ? (j as DemoTicket[]) : [];
  } catch {
    return [];
  }
}

export function createDemoTicket(tenantId: string, partial?: Partial<DemoTicket>): DemoTicket {
  const arr = listDemoTickets(tenantId);
  const t: DemoTicket = {
    id: `t_${Date.now()}_${crypto.randomBytes(4).toString("hex")}`,
    createdAt: nowISO(),
    subject: partial?.subject ?? "New request: Onboarding question",
    sender: partial?.sender ?? "client@example.com",
    status: partial?.status ?? "open",
    priority: partial?.priority ?? "medium",
    due: partial?.due,
  };
  arr.unshift(t);
  const p = fileFor(tenantId);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(arr, null, 2) + "\n");
  return t;
}
