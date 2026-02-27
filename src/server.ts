import express from "express";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { mountUi } from "./ui/routes";
import { upsertTicket } from "./lib/ticket-store";

type Tenant = { tenantId: string; tenantKey: string; notes?: string; createdAtUtc: string; updatedAtUtc: string };

const PORT = Number(process.env.PORT || 7090);
const DATA_DIR = process.env.DATA_DIR || "./data";
const ADMIN_KEY = process.env.ADMIN_KEY || "dev_admin_key_123";

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function tenantsFile() {
  return path.resolve(DATA_DIR, "tenants.json");
}

let _tenantsCache: Tenant[] | null = null;
let _tenantsMtime = 0;

function loadTenants(): Tenant[] {
  const fp = tenantsFile();
  try {
    const stats = fs.statSync(fp);
    if (_tenantsCache && stats.mtimeMs === _tenantsMtime) {
      return _tenantsCache;
    }

    const j = JSON.parse(fs.readFileSync(fp, "utf8"));
    const rows = Array.isArray(j?.tenants) ? (j.tenants as Tenant[]) : (Array.isArray(j) ? (j as Tenant[]) : []);

    _tenantsCache = rows;
    _tenantsMtime = stats.mtimeMs;
    return rows;
  } catch {
    return [];
  }
}

function saveTenants(rows: Tenant[]) {
  ensureDir(path.dirname(tenantsFile()));
  fs.writeFileSync(tenantsFile(), JSON.stringify({ ok: true, tenants: rows }, null, 2), "utf8");
}

function mustAdmin(req: any, res: any): boolean {
  const key = String(req.header("x-admin-key") || req.query?.adminKey || req.query?.key || "").trim();
  if (!key || key !== ADMIN_KEY) {
    res.status(401).json({ ok: false, error: "unauthorized" });
    return false;
  }
  return true;
}

function findTenant(tenantId: string): Tenant | undefined {
  return loadTenants().find(t => t.tenantId === tenantId);
}

function isValidTenantKey(tenantId: string, tenantKey: string): boolean {
  const t = findTenant(tenantId);
  return !!t && t.tenantKey === tenantKey;
}

function baseUrl(req: any) {
  const proto = String(req.headers["x-forwarded-proto"] || (req.socket?.encrypted ? "https" : "http"));
  const host = String(req.headers["x-forwarded-host"] || req.headers.host || "127.0.0.1");
  return `${proto}://${host}`;
}

function mkTenantId() {
  return `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
}
function mkKey() {
  return crypto.randomBytes(24).toString("base64url");
}

function computeMissing(lead: any): string[] {
  const missing: string[] = [];
  const email = String(lead?.email || "").trim();
  const fullName = String(lead?.fullName || "").trim();
  const phone = String(lead?.phone || "").trim();
  if (!email) missing.push("email");
  if (!fullName) missing.push("fullName");
  if (!email && !phone) missing.push("email_or_phone");
  return missing;
}

async function main() {
  ensureDir(DATA_DIR);

  const app = express();

  // global parsing (safe)
  app.use(express.urlencoded({ extended: true }));
  app.use(express.json({ limit: "2mb" }));

  // health
  app.get("/health", (_req, res) => res.json({ ok: true, name: "intake-guardian-agent", version: "gold-clean" }));

  // admin: list tenants (optional)
  app.get("/api/admin/tenants", (req, res) => {
    if (!mustAdmin(req, res)) return;
    return res.json({ ok: true, tenants: loadTenants() });
  });

  // admin: provision tenant (returns links + webhook)
  app.post("/api/admin/provision", (req, res) => {
    if (!mustAdmin(req, res)) return;

    const workspaceName = String(req.body?.workspaceName || "Workspace").trim();
    const agencyEmail = String(req.body?.agencyEmail || "").trim();
    const now = new Date().toISOString();

    const tenantId = mkTenantId();
    const k = mkKey();

    const rows = loadTenants();
    rows.push({ tenantId, tenantKey: k, notes: `provisioned:${workspaceName}:${agencyEmail}`, createdAtUtc: now, updatedAtUtc: now });
    saveTenants(rows);

    const b = baseUrl(req);

    const links = {
      welcome: `${b}/ui/welcome?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`,
      pilot:   `${b}/ui/pilot?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`,
      tickets: `${b}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`,
      csv:     `${b}/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`,
      zip:     `${b}/ui/evidence.zip?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`,
    };

    const webhookUrl = `${b}/api/webhook/easy?tenantId=${encodeURIComponent(tenantId)}`;

    return res.json({
      ok: true,
      baseUrl: b,
      tenantId,
      k,
      links,
      webhook: {
        url: webhookUrl,
        headers: { "content-type": "application/json", "x-tenant-key": k },
        bodyExample: { source: "zapier", type: "lead", lead: { fullName: "Jane Doe", email: "jane@example.com", company: "ACME" } }
      },
      curl:
        `curl -sS -X POST "${webhookUrl}" \\\n` +
        `  -H "content-type: application/json" \\\n` +
        `  -H "x-tenant-key: ${k}" \\\n` +
        `  --data '{"source":"demo","type":"lead","lead":{"fullName":"Demo Lead","email":"demo@x.dev","company":"DemoCo"}}'`
    });
  });

  // webhook: easy (validates key, creates ticket)
  app.post("/api/webhook/easy", (req, res) => {
    const tenantId = String(req.query?.tenantId || "").trim();
    const tenantKey = String(req.header("x-tenant-key") || "").trim();
    if (!tenantId || !tenantKey) return res.status(401).json({ ok: false, error: "unauthorized", hint: "need tenantId + x-tenant-key" });
    if (!isValidTenantKey(tenantId, tenantKey)) return res.status(401).json({ ok: false, error: "invalid_tenant_key" });

    const payload = req.body ?? {};
    const type = String(payload?.type || "lead");
    const source = String(payload?.source || "webhook");
    const lead = payload?.lead ?? {};

    const missing = computeMissing(lead);
    const flags = missing.length ? ["missing_fields", "low_signal"] : [];
    const title = `Lead intake (${source})`;

    const { ticket, created } = upsertTicket(tenantId, {
      source,
      type,
      title,
      payload,
      missingFields: missing,
      flags,
    });

    // return “ready / needs_review” style but keep internal statuses open/pending
    const apiStatus = missing.length ? "needs_review" : "ready";

    return res.json({
      ok: true,
      created,
      ticket: {
        id: ticket.id,
        status: apiStatus,
        title: ticket.title,
        source: ticket.source,
        type: ticket.type,
        dedupeKey: ticket.evidenceHash,
        flags: ticket.flags,
        missingFields: ticket.missingFields,
        duplicateCount: ticket.duplicateCount,
        createdAtUtc: ticket.createdAtUtc,
        lastSeenAtUtc: ticket.lastSeenAtUtc
      }
    });
  });

  // UI helper: send test lead (uses easy webhook)
  app.post("/api/ui/send-test-lead", (req, res) => {
    const tenantId = String(req.query?.tenantId || "").trim();
    const k = String(req.query?.k || "").trim();
    if (!tenantId || !k) return res.status(401).json({ ok: false, error: "unauthorized", hint: "need tenantId + k" });

    // re-use internal logic: validate & write ticket directly
    if (!isValidTenantKey(tenantId, k)) return res.status(401).json({ ok: false, error: "invalid_tenant_key" });

    const payload = {
      source: "ui",
      type: "lead",
      lead: { fullName: "UI Test Lead", email: "ui-test@local.dev", company: "DecisionCover" }
    };

    const missing = computeMissing(payload.lead);
    const flags = missing.length ? ["missing_fields", "low_signal"] : [];
    const title = `Lead intake (ui)`;

    const { ticket, created } = upsertTicket(tenantId, {
      source: payload.source,
      type: payload.type,
      title,
      payload,
      missingFields: missing,
      flags,
    });

    const apiStatus = missing.length ? "needs_review" : "ready";

    // redirect back to tickets for zero-tech UX
    const b = baseUrl(req);
    res.setHeader("location", `${b}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`);
    return res.status(303).json({
      ok: true,
      created,
      ticket: {
        id: ticket.id,
        status: apiStatus,
        title: ticket.title,
        source: ticket.source,
        type: ticket.type,
        dedupeKey: ticket.evidenceHash,
        flags: ticket.flags,
        missingFields: ticket.missingFields,
        duplicateCount: ticket.duplicateCount,
        createdAtUtc: ticket.createdAtUtc,
        lastSeenAtUtc: ticket.lastSeenAtUtc
      }
    });
  });

  // UI routes (tickets, csv, zip, pilot)
  mountUi(app);

  // root
  app.get("/", (_req, res) => res.redirect("/ui/welcome"));

  app.listen(PORT, () => {
    console.log("Intake-Guardian running on", PORT);
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
