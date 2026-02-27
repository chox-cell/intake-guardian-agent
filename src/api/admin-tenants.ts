import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import type { Express, Request, Response } from "express";

type TenantRec = {
  tenantId: string;
  key: string;
  createdAt: string;
  rotatedAt?: string;
};

function nowIso() { return new Date().toISOString(); }

function randId(prefix: string) {
  return `${prefix}_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
}

function randKey() {
  return crypto.randomBytes(16).toString("base64url");
}

function dataFile(dataDir: string) {
  return path.join(dataDir, "admin.tenants.json");
}

function readAll(dataDir: string): TenantRec[] {
  const fp = dataFile(dataDir);
  if (!fs.existsSync(fp)) return [];
  try {
    const raw = fs.readFileSync(fp, "utf8");
    const j = JSON.parse(raw);
    if (Array.isArray(j)) return j as TenantRec[];
    return [];
  } catch {
    return [];
  }
}

function writeAll(dataDir: string, rows: TenantRec[]) {
  const fp = dataFile(dataDir);
  fs.mkdirSync(path.dirname(fp), { recursive: true });
  fs.writeFileSync(fp, JSON.stringify(rows, null, 2) + "\n");
}

function pickAdminKey(req: Request) {
  // compat: query ?admin= ?ak= header x-admin-key
  const q = req.query as any;
  const fromQuery = (q.admin || q.ak || "") as string;
  const fromHeader = (req.headers["x-admin-key"] || "") as string;
  return String(fromQuery || fromHeader || "");
}

function requireAdmin(req: Request, res: Response): string | null {
  const envKey = process.env.ADMIN_KEY || "";
  const got = pickAdminKey(req);

  if (!envKey) {
    res.status(500).send("admin_key_not_configured");
    return null;
  }
  if (!got || got !== envKey) {
    res.status(401).send("admin_unauthorized");
    return null;
  }
  return envKey;
}

export function mountAdminTenantsApi(app: Express, args: { dataDir: string }) {
  const base = "/api/admin/tenants";

  // LIST
  app.get(base, (req, res) => {
    if (!requireAdmin(req, res)) return;
    const rows = readAll(args.dataDir);
    res.json({ ok: true, tenants: rows.map(r => ({ tenantId: r.tenantId, createdAt: r.createdAt, rotatedAt: r.rotatedAt })) });
  });

  // CREATE (always returns tenantId + key)
  app.post(`${base}/create`, (req, res) => {
    if (!requireAdmin(req, res)) return;
    const rows = readAll(args.dataDir);

    const tenantId = randId("tenant");
    const key = randKey();

    const rec: TenantRec = { tenantId, key, createdAt: nowIso() };
    rows.push(rec);
    writeAll(args.dataDir, rows);

    res.json({ ok: true, tenantId, key });
  });

  // ROTATE (requires tenantId)
  app.post(`${base}/rotate`, (req, res) => {
    if (!requireAdmin(req, res)) return;

    const body: any = req.body || {};
    const tenantId = String(body.tenantId || req.query.tenantId || "");
    if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });

    const rows = readAll(args.dataDir);
    const idx = rows.findIndex(r => r.tenantId === tenantId);
    if (idx === -1) return res.status(404).json({ ok: false, error: "tenant_not_found" });

    rows[idx].key = randKey();
    rows[idx].rotatedAt = nowIso();
    writeAll(args.dataDir, rows);

    res.json({ ok: true, tenantId, key: rows[idx].key });
  });
}
