import { Router } from "express";
import { z } from "zod";
import { Store } from "../store/store.js";
import { createAgent } from "../plugin/createAgent.js";
import { requireTenantKey } from "./tenant-key.js";
import { HttpError } from "./tenant-key.js";
import { authRouter } from "./auth";

export function makeRoutes(args: {
  store: Store;
  presetId: string;
  dedupeWindowSeconds: number;
}) {
  const r = Router();

  const agent = createAgent({
    store: args.store,
    presetId: args.presetId,
    dedupeWindowSeconds: args.dedupeWindowSeconds
  });

  r.get("/health", async (_req, res) => {
    res.json({ ok: true });
  });

  // Core intake (generic) — expects InboundEvent contract with tenantId in body
  r.post("/intake", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.body?.tenantId);
    try {
      requireTenantKey(req, tenantId);
    } catch (e) {
  const err = e as any;    }
    const out = await agent.intake(req.body);
    res.json(out);
  });

  r.get("/workitems", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    try {
      requireTenantKey(req, tenantId);
    } catch (e) {
  const err = e as any;
      return res.status((err?.status) || 401).json({ ok: false, error: (err?.code) || "invalid_tenant_key" });
    }
    const status = req.query.status
      ? z.enum(["new", "triage", "in_progress", "waiting", "resolved", "closed"]).parse(req.query.status)
      : undefined;

    const search = req.query.search ? z.string().min(1).parse(req.query.search) : undefined;

    const limit = req.query.limit
      ? z.coerce.number().int().min(1).max(200).parse(req.query.limit)
      : 50;

    const offset = req.query.offset
      ? z.coerce.number().int().min(0).parse(req.query.offset)
      : 0;

    const items = await args.store.listWorkItems(tenantId, { status, search, limit, offset });
    res.json({ ok: true, items });
  });

  r.get("/workitems/:id", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    try {
      requireTenantKey(req, tenantId);
    } catch (e) {
  const err = e as any;
      return res.status((err?.status) || 401).json({ ok: false, error: (err?.code) || "invalid_tenant_key" });
    }
    const item = await args.store.getWorkItem(tenantId, req.params.id);
    if (!item) return res.status(404).json({ ok: false, error: "not_found" });
    res.json({ ok: true, item });
  });

  r.post("/workitems/:id/status", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.body.tenantId);
    try {
      requireTenantKey(req, tenantId);
    } catch (e) {
  const err = e as any;
      return res.status((err?.status) || 401).json({ ok: false, error: (err?.code) || "invalid_tenant_key" });
    }
    const next = req.body.next;
    const out = await agent.updateStatus(tenantId, req.params.id, next);

    if (!out.ok && (out as any).error === "not_found") return res.status(404).json(out);
    if (!out.ok) return res.status(400).json(out);

    res.json(out);
  });

  r.post("/workitems/:id/owner", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.body.tenantId);
    try {
      requireTenantKey(req, tenantId);
    } catch (e) {
  const err = e as any;
      return res.status((err?.status) || 401).json({ ok: false, error: (err?.code) || "invalid_tenant_key" });
    }
    const ownerId = req.body.ownerId ?? null;
    const out = await agent.assignOwner(tenantId, req.params.id, ownerId);

    if (!out.ok && (out as any).error === "not_found") return res.status(404).json(out);
    res.json(out);
  });

  r.get("/workitems/:id/events", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    try {
      requireTenantKey(req, tenantId);
    } catch (e) {
  const err = e as any;
      return res.status((err?.status) || 401).json({ ok: false, error: (err?.code) || "invalid_tenant_key" });
    }
    const limit = req.query.limit
      ? z.coerce.number().int().min(1).max(1000).parse(req.query.limit)
      : 200;

    const events = await args.store.listAudit(tenantId, req.params.id, limit);
    res.json({ ok: true, events });
  });

  return r;
}

