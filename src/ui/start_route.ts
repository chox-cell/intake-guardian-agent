import type { Express, Request, Response } from "express";
import { createTenant, getOrCreateDemoTenant } from "../lib/tenant_registry.js";

function isAdminOk(req: Request) {
  return (req.query.adminKey as string) === process.env.ADMIN_KEY;
}

export function mountStart(app: Express) {
  app.get("/ui/start", async (req: Request, res: Response) => {
    if (!isAdminOk(req)) return res.status(401).send("unauthorized");
    const tenant = await getOrCreateDemoTenant();
    const url =
      `/ui/setup?tenantId=${tenant.tenantId}` +
      `&k=${tenant.tenantKey}`;
    res.redirect(302, url); // Security: relative redirect to prevent open redirect
  });
}
