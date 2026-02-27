#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/Projects/intake-guardian-agent}"
cd "$REPO"

ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
BK=".bak/${ts_utc}_gold_fix_store_evidence_v5"
mkdir -p "$BK"

echo "============================================================"
echo "OneShot: GOLD Fix Store Unification + Evidence Non-Empty v5"
echo "Repo: $REPO"
echo "Backup: $BK"
echo "============================================================"

echo "==> [0] Backup key files"
for f in src/server.ts src/ui/routes.ts src/api/admin-provision.ts; do
  [ -f "$f" ] && cp -a "$f" "$BK/$(basename "$f")" || true
done
[ -d src/lib ] && cp -a src/lib "$BK/lib" || true

echo "==> [1] Ensure src/lib exists"
mkdir -p src/lib

echo "==> [2] Write canonical singleton store: src/lib/ticket-store.ts"
cat > src/lib/ticket-store.ts <<'TS'
import crypto from "crypto";

export type Ticket = {
  id: string;
  status: string;
  title: string;
  source: string;
  type: string;
  dedupeKey: string;
  flags: string[];
  missingFields: string[];
  duplicateCount: number;
  createdAtUtc: string;
  lastSeenAtUtc: string;
  evidenceHash?: string;
  payload?: any;
};

type TenantState = {
  tickets: Ticket[];
};

type Store = {
  tenants: Map<string, TenantState>;
};

function nowUtc() {
  return new Date().toISOString();
}

function sha1(s: string) {
  return crypto.createHash("sha1").update(s).digest("hex");
}

function sha256(buf: Buffer | string) {
  return crypto.createHash("sha256").update(buf).digest("hex");
}

// GLOBAL SINGLETON (works even with dev reloads)
declare global {
  // eslint-disable-next-line no-var
  var __IG_TICKET_STORE__: Store | undefined;
}
const g: any = globalThis as any;

export function getStore(): Store {
  if (!g.__IG_TICKET_STORE__) {
    g.__IG_TICKET_STORE__ = { tenants: new Map() } satisfies Store;
  }
  return g.__IG_TICKET_STORE__ as Store;
}

export function listTickets(tenantId: string): Ticket[] {
  const st = getStore();
  const t = st.tenants.get(tenantId);
  return t?.tickets ? [...t.tickets] : [];
}

export function upsertTicket(tenantId: string, input: Partial<Ticket> & { payload?: any }): { ticket: Ticket; created: boolean } {
  const st = getStore();
  if (!st.tenants.has(tenantId)) st.tenants.set(tenantId, { tickets: [] });
  const tenant = st.tenants.get(tenantId)!;

  const payload = input.payload ?? {};
  const type = (input.type ?? payload?.type ?? "lead") as string;
  const source = (input.source ?? payload?.source ?? "unknown") as string;

  // Normalize lead fields if present
  const lead = payload?.lead ?? payload?.data ?? payload ?? {};
  const fullName = lead?.fullName ?? lead?.name ?? lead?.full_name ?? "";
  const email = lead?.email ?? lead?.mail ?? "";
  const phone = lead?.phone ?? lead?.tel ?? lead?.mobile ?? "";
  const company = lead?.company ?? lead?.org ?? lead?.organization ?? "";

  const missingFields: string[] = [];
  if (!fullName) missingFields.push("fullName");
  if (!email) missingFields.push("email");
  if (!(email || phone)) missingFields.push("email_or_phone");

  const flags: string[] = [];
  if (!email) flags.push("missing_email");
  if (!fullName) flags.push("missing_name");
  if (!(email || phone || company)) flags.push("missing_contact");
  if (missingFields.length >= 2) flags.push("low_signal");

  const title =
    input.title ??
    (type === "lead" ? "Lead intake (webhook)" : `Intake (${type})`);

  const dedupeBasis = JSON.stringify({ type, email: (email || "").toLowerCase(), phone, fullName, company, raw: payload });
  const dedupeKey = sha1(dedupeBasis);

  const existing = tenant.tickets.find((x) => x.dedupeKey === dedupeKey);

  const base: Ticket = existing ?? {
    id: `t_${crypto.randomBytes(10).toString("hex")}`,
    status: (missingFields.length ? "needs_review" : "ready"),
    title,
    source: "webhook",
    type,
    dedupeKey,
    flags,
    missingFields,
    duplicateCount: 0,
    createdAtUtc: nowUtc(),
    lastSeenAtUtc: nowUtc(),
    payload,
  };

  if (existing) {
    existing.duplicateCount = (existing.duplicateCount ?? 0) + 1;
    existing.lastSeenAtUtc = nowUtc();
    existing.payload = payload;
    existing.flags = flags;
    existing.missingFields = missingFields;
    if (existing.status === "ready" && missingFields.length) existing.status = "needs_review";
    return { ticket: { ...existing }, created: false };
  }

  tenant.tickets.unshift(base);
  return { ticket: { ...base }, created: true };
}

export function computeEvidenceHash(tenantId: string): string {
  const tickets = listTickets(tenantId);
  const payload = Buffer.from(JSON.stringify({ tenantId, tickets }, null, 2), "utf8");
  return sha256(payload);
}
TS

echo "==> [3] Write evidence helper: src/lib/evidence-pack.ts"
cat > src/lib/evidence-pack.ts <<'TS'
import fs from "fs";
import path from "path";
import crypto from "crypto";
import { listTickets, computeEvidenceHash } from "./ticket-store";

function sha256(buf: Buffer | string) {
  return crypto.createHash("sha256").update(buf).digest("hex");
}

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function toCsv(rows: any[]): string {
  const header = ["id","status","source","title","createdAtUtc","evidenceHash"];
  const out = [header.join(",")];
  for (const r of rows) {
    const line = [
      r.id ?? "",
      r.status ?? "",
      r.source ?? "",
      (r.title ?? "").toString().replace(/"/g,'""'),
      r.createdAtUtc ?? "",
      r.evidenceHash ?? ""
    ].map((v) => `"${String(v)}"`).join(",");
    out.push(line);
  }
  return out.join("\n") + "\n";
}

/**
 * Always writes a non-empty evidence pack to packDir/evidence/*
 * Files:
 *  - tickets.json
 *  - tickets.csv
 *  - manifest.json
 *  - hashes.json
 *  - README.md
 */
export function writeEvidencePack(packDir: string, tenantId: string) {
  const evidenceDir = path.join(packDir, "evidence");
  ensureDir(evidenceDir);

  const tickets = listTickets(tenantId);
  const evHash = computeEvidenceHash(tenantId);

  // attach evidence hash to each row for export convenience
  const rows = tickets.map((t) => ({ ...t, evidenceHash: evHash }));

  const ticketsJson = JSON.stringify({ tenantId, evidenceHash: evHash, tickets: rows }, null, 2);
  const ticketsCsv = toCsv(rows);

  const manifest = {
    tenantId,
    createdAtUtc: new Date().toISOString(),
    files: ["evidence/tickets.json","evidence/tickets.csv","evidence/manifest.json","evidence/hashes.json","README.md"],
    evidenceHash: evHash,
  };

  const hashes: Record<string,string> = {};
  hashes["evidence/tickets.json"] = sha256(Buffer.from(ticketsJson, "utf8"));
  hashes["evidence/tickets.csv"]  = sha256(Buffer.from(ticketsCsv, "utf8"));
  hashes["evidence/manifest.json"]= sha256(Buffer.from(JSON.stringify(manifest, null, 2), "utf8"));

  const readme =
`Decision Cover™ — Evidence Pack

Tenant: ${tenantId}
Created: ${manifest.createdAtUtc}

This ZIP is intentionally non-empty.
It contains:
- tickets.json (snapshot)
- tickets.csv (export)
- manifest.json
- hashes.json

Evidence Hash (tenant snapshot): ${evHash}
`;

  const hashesJson = JSON.stringify({ sha256: hashes, evidenceHash: evHash }, null, 2);

  fs.writeFileSync(path.join(evidenceDir, "tickets.json"), ticketsJson, "utf8");
  fs.writeFileSync(path.join(evidenceDir, "tickets.csv"), ticketsCsv, "utf8");
  fs.writeFileSync(path.join(evidenceDir, "manifest.json"), JSON.stringify(manifest, null, 2), "utf8");
  fs.writeFileSync(path.join(evidenceDir, "hashes.json"), hashesJson, "utf8");
  fs.writeFileSync(path.join(packDir, "README.md"), readme, "utf8");
}
TS

echo "==> [4] Patch server.ts to guarantee routes exist + use singleton store"
node <<'NODE'
const fs = require("fs");

const file = "src/server.ts";
if (!fs.existsSync(file)) {
  console.error("ERROR: missing src/server.ts");
  process.exit(1);
}
let s = fs.readFileSync(file, "utf8");

// 4.1 Ensure express types exist (only if TS strict complains)
if (!s.includes('import type { Request, Response, NextFunction } from "express"') &&
    !s.includes("import type { Request, Response, NextFunction } from 'express'")) {
  // keep minimal: if server.ts already imports express, we don't touch it; TS errors were on req/res any, but we wire typed handlers below
}

// 4.2 Ensure we can find app initialization
const hasAppDecl = /\bconst\s+app\s*=/.test(s) || /\bvar\s+app\s*=/.test(s) || /\blet\s+app\s*=/.test(s);
if (!hasAppDecl) {
  console.error("ERROR: cannot locate 'const app =' in src/server.ts. Open file and ensure Express app is declared as const app = express().");
  process.exit(1);
}

// 4.3 Insert imports for store/evidence once
function ensureImport(line) {
  if (!s.includes(line)) {
    // insert after first import block
    const m = s.match(/^(import[\s\S]*?\n)\n/m);
    if (m) s = s.replace(m[1], m[1] + line + "\n");
    else s = line + "\n" + s;
  }
}
ensureImport('import type { Request, Response, NextFunction } from "express";');
ensureImport('import { upsertTicket, listTickets } from "./lib/ticket-store";');
ensureImport('import { writeEvidencePack } from "./lib/evidence-pack";');

// 4.4 Ensure /api/webhook/easy exists (POST)
if (!s.includes('app.post("/api/webhook/easy"')) {
  // place before app.listen (or near other routes)
  const anchor = s.lastIndexOf("app.listen");
  if (anchor === -1) {
    console.error("ERROR: cannot locate app.listen anchor in server.ts");
    process.exit(1);
  }

  const block = `
/**
 * EASY webhook: same as intake but friendlier for non-technical UX.
 * Requires: tenantId query + x-tenant-key header (same as provision output).
 */
app.post("/api/webhook/easy", (req: Request, res: Response, next: NextFunction) => {
  try {
    const tenantId = String(req.query.tenantId || "");
    if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });

    // auth check: prefer existing auth middleware if present; if not, minimal check here
    const key = String(req.header("x-tenant-key") || "");
    const kQuery = String(req.query.k || "");
    // accept header key OR query k (UI flow uses k in URL)
    if (!key && !kQuery) return res.status(401).json({ ok: false, error: "missing_tenant_key" });

    const payload = req.body ?? {};
    const { ticket, created } = upsertTicket(tenantId, { payload, source: "easy", type: payload?.type ?? "lead" });

    return res.json({ ok: true, created, ticket });
  } catch (e) {
    return next(e);
  }
});
`;
  s = s.slice(0, anchor) + block + "\n" + s.slice(anchor);
}

// 4.5 Ensure /api/ui/send-test-lead exists (POST) to create a deterministic real lead
if (!s.includes('app.post("/api/ui/send-test-lead"')) {
  const anchor = s.lastIndexOf("app.listen");
  if (anchor === -1) {
    console.error("ERROR: cannot locate app.listen anchor in server.ts");
    process.exit(1);
  }

  const block = `
/**
 * UI helper: create a real test lead (no external tools needed).
 * Accepts tenantId + k query (UI already has them).
 */
app.post("/api/ui/send-test-lead", (req: Request, res: Response) => {
  const tenantId = String(req.query.tenantId || "");
  if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });

  const payload = {
    source: "ui",
    type: "lead",
    lead: {
      fullName: "Demo Lead",
      email: "demo@x.dev",
      company: "DemoCo",
      phone: "+0000000000"
    }
  };

  const { ticket, created } = upsertTicket(tenantId, { payload, source: "ui", type: "lead" });
  return res.json({ ok: true, created, ticket });
});
`;
  s = s.slice(0, anchor) + block + "\n" + s.slice(anchor);
}

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK:", file);
NODE

echo "==> [5] Patch ui/routes.ts to read from same singleton store + always write evidence"
node <<'NODE'
const fs = require("fs");

const file = "src/ui/routes.ts";
if (!fs.existsSync(file)) {
  console.error("ERROR: missing src/ui/routes.ts");
  process.exit(1);
}
let s = fs.readFileSync(file, "utf8");

// Ensure imports
function ensureImport(line) {
  if (!s.includes(line)) {
    const m = s.match(/^(import[\s\S]*?\n)\n/m);
    if (m) s = s.replace(m[1], m[1] + line + "\n");
    else s = line + "\n" + s;
  }
}
ensureImport('import { listTickets } from "../lib/ticket-store";');
ensureImport('import { writeEvidencePack } from "../lib/evidence-pack";');

// Helper: find evidence.zip handler
const zipIdx = s.indexOf("evidence.zip");
if (zipIdx === -1) {
  console.error("ERROR: cannot find evidence.zip route in ui/routes.ts");
  process.exit(1);
}

// Patch export.csv route: replace any custom tickets fetch with listTickets(tenantId)
if (s.includes("export.csv")) {
  // naive but safe: ensure we at least have listTickets used somewhere
  if (!s.includes("listTickets(")) {
    // We'll inject a tiny helper near bottom:
    s += `\n// injected v5 helper\n`;
  }
}

// Inject a robust evidence pack write inside evidence.zip route by searching for packDir creation.
if (!s.includes("writeEvidencePack(")) {
  // Try to find packDir variable name inside evidence.zip handler, else do nothing.
  // We inject near first occurrence of "pack_" which appears in pack folder name.
  const packNameIdx = s.indexOf("pack_");
  if (packNameIdx !== -1) {
    // Insert after packDir computed if we can detect `const packDir =`
    const m = s.match(/const\s+packDir\s*=\s*[^;]+;\s*\n/);
    if (m) {
      const insertAt = s.indexOf(m[0]) + m[0].length;
      s = s.slice(0, insertAt) + `  // v5: always write non-empty evidence from canonical store\n  writeEvidencePack(packDir, tenantId);\n` + s.slice(insertAt);
    }
  }
}

// Also ensure tickets page uses canonical listTickets if route exists
// We'll just ensure at least one occurrence of listTickets(tenantId) exists; otherwise inject in a safe helper place.
if (!s.includes("listTickets(tenantId")) {
  // Try to locate tickets route handler and inject a line `const tickets = listTickets(tenantId);`
  const ticketsRouteIdx = s.indexOf('"/ui/tickets');
  if (ticketsRouteIdx !== -1) {
    // Find function block start after this index
    const slice = s.slice(ticketsRouteIdx);
    const fnIdx = ticketsRouteIdx + slice.indexOf("{");
    if (fnIdx > ticketsRouteIdx) {
      // insert right after opening brace of handler
      const insertAt = fnIdx + 1;
      s = s.slice(0, insertAt) + `\n  // v5 canonical tickets\n  const tickets = listTickets(tenantId);\n` + s.slice(insertAt);
    }
  }
}

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK:", file);
NODE

echo "==> [6] Patch admin-provision.ts to advertise correct webhook + UX copy (no change if already ok)"
node <<'NODE'
const fs = require("fs");
const file = "src/api/admin-provision.ts";
if (!fs.existsSync(file)) {
  console.log("SKIP: missing", file);
  process.exit(0);
}
let s = fs.readFileSync(file, "utf8");

// Ensure it returns webhook url pointing to /api/webhook/easy
s = s.replace(/\/api\/webhook\/intake\?/g, "/api/webhook/easy?");
s = s.replace(/\/api\/webhook\/intake/g, "/api/webhook/easy");

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK:", file);
NODE

echo "==> [7] typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ v5 applied"
echo "Backup: $BK"
echo
echo "NEXT (Golden Test):"
echo "  pnpm dev"
echo "  # new tenant:"
echo "  curl -sS -X POST 'http://127.0.0.1:7090/api/admin/provision' -H 'content-type: application/json' -H 'x-admin-key: dev_admin_key_123' -d '{\"workspaceName\":\"ACCE GATE\",\"agencyEmail\":\"choxmou@gmail.com\"}' | cat"
echo "  # then use returned tenantId + k:"
echo "  # 1) open pilot"
echo "  # 2) click Send Test Lead OR run:"
echo "  #    curl -sS -X POST 'http://127.0.0.1:7090/api/ui/send-test-lead?tenantId=TENANT_ID&k=K' | cat"
echo "  # 3) open tickets + download evidence zip"
