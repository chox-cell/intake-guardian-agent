import express from "express";
import type { TenantsStore } from "../tenants/store.js";
import { requireTenantKey } from "./tenant-key.js";
import { HttpError } from "./tenant-key.js";

export function makeOutboundRoutes(args: { store: any; tenants: TenantsStore }) {
  const r = express.Router();

  // Admin list (requires x-admin-key at server level; server.ts should gate)
  r.get("/admin/tenants", (_req, res) => {
    return res.json({
      ok: true,
      tenants: args.tenants.list().map((t) => ({ tenantId: t.tenantId, createdAt: t.createdAt, rotatedAt: t.rotatedAt })),
    });
  });

  r.post("/admin/tenants/create", (req, res) => {
    const out = args.tenants.upsertNew();
    return res.json({ ok: true, tenantId: out.tenantId, tenantKey: out.tenantKey });
  });

  r.post("/admin/tenants/rotate", (req, res) => {
    const body = (req.body || {}) as any;
    if (!body.tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });
    const out = args.tenants.rotate(String(body.tenantId));
    if (!out.ok) return res.status(404).json({ ok: false, error: out.error });
    return res.json({ ok: true, tenantId: out.tenantId, tenantKey: out.tenantKey });
  });

  // Optional slack outbound stub (kept compatible with earlier demos)
  r.post("/slack", async (req, res) => {
    const tenantId = (typeof req.query.tenantId === "string" ? req.query.tenantId : "").trim();
    if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });

    const tk = requireTenantKey(req as any, tenantId, args.tenants, undefined);
    const body = (req.body || {}) as any;
    const workItemId = String(body.workItemId || "");
    if (!workItemId) return res.status(400).json({ ok: false, error: "missing_workItemId" });

    const webhook = process.env.SLACK_WEBHOOK_URL;
    if (!webhook) return res.status(400).json({ ok: false, error: "missing_slack_webhook_url" });

    // Minimal payload
    const payload = { text: `New ticket ${workItemId} (tenant=${tenantId})` };
    const r2 = await fetch(webhook, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
    if (!r2.ok) return res.status(502).json({ ok: false, error: "slack_failed", status: r2.status });

    return res.json({ ok: true });
  });

  return r;
}
