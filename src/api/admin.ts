import type { Express, Request, Response } from "express";
import { createTenant, listTenants, rotateTenantKey, getTenant } from "../lib/tenant_registry.js";

const DATA_DIR = process.env.DATA_DIR || "./data";


function adminKeyOk(req: Request) {
  const expected = process.env.ADMIN_KEY || "";
  if (!expected) return false;
  const q = (req.query.admin as string) || "";
  const h = (req.headers["x-admin-key"] as string) || "";
  const a = (req.headers["authorization"] as string) || "";
  const bearer = a.toLowerCase().startsWith("bearer ") ? a.slice(7) : "";
  return q === expected || h === expected || bearer === expected;
}

function deny(res: Response, code = 401, msg = "unauthorized") {
  return res.status(code).json({ ok: false, error: msg });
}

export function mountAdminApi(app: Express) {
  // GET /api/admin/tenants
  app.get("/api/admin/tenants", async (req, res) => {
    if (!adminKeyOk(req)) return deny(res);
    const tenants = await listTenants();
    return res.json({
      ok: true,
      tenants: tenants.map(t => ({
        tenantId: t.tenantId,
        tenantKey: t.tenantKey, // admin only
        createdAtUtc: t.createdAtUtc,
        updatedAtUtc: t.updatedAtUtc,
        notes: t.notes || null,
      })),
    });
  });

  // GET /api/admin/tenants/:id
  app.get("/api/admin/tenants/:id", async (req, res) => {
    if (!adminKeyOk(req)) return deny(res);
    const tenantId = req.params.id;
    const t = await getTenant(DATA_DIR, tenantId);
    if (!t) return deny(res, 404, "tenant_not_found");
    return res.json({ ok: true, tenant: t });
  });

  // POST /api/admin/tenants  { notes? }
  app.post("/api/admin/tenants", async (req, res) => {
    if (!adminKeyOk(req)) return deny(res);
    const notes = (req.body && typeof req.body.notes === "string") ? req.body.notes : "";
    const t = await createTenant(undefined, notes);
    return res.json({ ok: true, tenantId: t.tenantId, tenantKey: t.tenantKey });
  });

  // POST /api/admin/tenants/:id/rotate
  app.post("/api/admin/tenants/:id/rotate", async (req, res) => {
    if (!adminKeyOk(req)) return deny(res);
    const tenantId = req.params.id;
    const t = await rotateTenantKey(DATA_DIR, tenantId);
    if (!t) return deny(res, 404, "tenant_not_found");
    return res.json({ ok: true, tenantId: t.tenantId, tenantKey: t.tenantKey });
  });
}
