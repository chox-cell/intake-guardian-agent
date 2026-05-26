import type { Express, Request, Response } from "express";
import { createTenant, getOrCreateDemoTenant } from "../lib/tenant_registry.js";

function baseUrl(req: Request) {
  const proto = (req.headers["x-forwarded-proto"] as string) || "http";
  const host =
    (req.headers["x-forwarded-host"] as string) ||
    (req.headers.host as string) ||
    "127.0.0.1:7090";
  return `${proto}://${host}`;
}

function isAdminOk(req: Request) {
  return (req.query.adminKey as string) === process.env.ADMIN_KEY;
}

export function mountStart(app: Express) {
  app.get("/ui/start", async (req: Request, res: Response) => {
    if (!isAdminOk(req)) return res.status(401).send("unauthorized");
    const tenant = await getOrCreateDemoTenant();

    // Prevent Host Header Injection / Open Redirect: Prefer relative paths unless explicit base URL is trusted
    const explicitBase = process.env.APP_BASE_URL;
    const destBase = explicitBase ? String(explicitBase).trim() : "";
    const url =
      `${destBase}/ui/setup?tenantId=${tenant.tenantId}` +
      `&k=${tenant.tenantKey}`;
    res.redirect(302, url);
  });
}
