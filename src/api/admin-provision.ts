import type { Request, Response } from "express";
/* UX_EASY_NO_HEADERS_WEBHOOK */
function __tenantKeyFromReq(req: any) {
  // Prefer headers (Zapier/Make/n8n). Fallback to query k (Google Forms/Webflow/Typeform).
  return String(
    (req?.headers?.["x-tenant-key"] ||
     req?.headers?.["x-tenant-token"] ||
     req?.query?.k ||
     req?.query?.key ||
     "")
  ).trim();
}
import crypto from "crypto";
import fs from "fs";
import path from "path";

type TenantRecord = {
  tenantId: string;
  k: string;
  createdAt: string;
  label?: string;
  email?: string;
};

type TenantStore = {
  tenants: TenantRecord[];
};

function baseUrlFromReq(req: Request) {
  const proto = (req.headers["x-forwarded-proto"] as string) || req.protocol || "http";
  const host = (req.headers["x-forwarded-host"] as string) || req.get("host") || "127.0.0.1:7090";
  return `${proto}://${host}`;
}

function nowISO() {
  return new Date().toISOString();
}

function randId(prefix: string) {
  return `${prefix}_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
}

function randKey() {
  // url-safe
  return crypto.randomBytes(24).toString("base64url");
}

function getDataDir(req: Request) {
  const anyReq = req as any;
  const dataDir = (anyReq?.app?.locals?.DATA_DIR as string) || process.env.DATA_DIR || "./data";
  return dataDir;
}

function loadStore(filePath: string): TenantStore {
  try {
    const raw = fs.readFileSync(filePath, "utf8");
    const parsed = JSON.parse(raw);
    if (parsed && Array.isArray(parsed.tenants)) return parsed as TenantStore;
  } catch {}
  return { tenants: [] };
}

function saveStore(filePath: string, store: TenantStore) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(store, null, 2), "utf8");
}

function requireAdminKey(req: Request): string | null {
  const header = (req.headers["x-admin-key"] as string) || "";
  const q = (req.query.adminKey as string) || "";
  const adminKey = header || q;

  const expected = process.env.ADMIN_KEY || "";
  if (!expected) return null;
  if (!adminKey) return null;
  if (adminKey !== expected) return null;
  return adminKey;
}

export function postAdminProvision(req: Request, res: Response) {
  const ok = requireAdminKey(req);
  if (!ok) return res.status(401).json({ ok: false, error: "unauthorized" });

  const { email, label } = (req.body || {}) as { email?: string; label?: string };

  const tenantId = randId("tenant");
  const k = randKey();

  const dataDir = getDataDir(req);
  const storeFile = path.join(dataDir, "tenants", "tenants.json");

  const store = loadStore(storeFile);
  store.tenants.unshift({
    tenantId,
    k,
    createdAt: nowISO(),
    email,
    label,
  });
  saveStore(storeFile, store);

  const baseUrl = baseUrlFromReq(req);

  const qs = `tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
  const links = {
    welcome:   `${baseUrl}/ui/welcome?${qs}`,
    pilot:     `${baseUrl}/ui/pilot?${qs}`,
    decisions: `${baseUrl}/ui/decisions?${qs}`,
    tickets:   `${baseUrl}/ui/tickets?${qs}`,
    setup:     `${baseUrl}/ui/setup?${qs}`,
    csv:       `${baseUrl}/ui/export.csv?${qs}`,
    zip:       `${baseUrl}/ui/evidence.zip?${qs}`,
  };

  const webhook = {
    url: `${baseUrl}/api/webhook/easy?tenantId=${encodeURIComponent(tenantId)}`,
    headers: {
      "content-type": "application/json",
      "x-tenant-key": k,
    },
    bodyExample: {
      source: "zapier",
      type: "lead",
      lead: { fullName: "Jane Doe", email: "jane@example.com", company: "ACME" },
    },
  };

  const curl = `curl -sS -X POST "${webhook.url}" \\
  -H "content-type: application/json" \\
  -H "x-tenant-key: ${k}" \\
  --data '{"source":"demo","type":"lead","lead":{"fullName":"Demo Lead","email":"demo@x.dev","company":"DemoCo"}}'`;

  return res.status(201).json({
    ok: true,
    baseUrl,
    tenantId,
    k,
    links,
    webhook,
    curl,
  });
}
