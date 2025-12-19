import { Router } from "express";
import { z } from "zod";
import nodemailer from "nodemailer";
import type { Store } from "../store/store.js";
import { requireTenantKey } from "./tenant-key.js";
import { TenantsStore } from "../tenants/store.js";

function requireAdminKey(req: any) {
  const expected = (process.env.ADMIN_KEY || "").trim();
  if (!expected) return { ok: false as const, status: 500, error: "missing_admin_key_env" as const };
  const got = (req.header("x-admin-key") || "").trim();
  if (!got) return { ok: false as const, status: 401, error: "missing_admin_key" as const };
  if (got !== expected) return { ok: false as const, status: 403, error: "invalid_admin_key" as const };
  return { ok: true as const };
}

function csvEscape(v: any) {
  const s = String(v ?? "");
  const needs = /[",\n]/.test(s);
  const out = s.replace(/"/g, '""');
  return needs ? `"${out}"` : out;
}

export function makeOutboundRoutes(args: { store: Store; tenants: TenantsStore }) {
  const r = Router();

  // ---------------------------
  // (1) Tenant admin: create/rotate/list
  // ---------------------------
  r.post("/admin/tenants/create", async (req, res) => {
    const ak = requireAdminKey(req);
    if (!ak.ok) return res.status(ak.status).json({ ok: false, error: ak.error });

    const schema = z.object({ tenantId: z.string().min(3).max(64).optional() });
    const body = schema.parse(req.body || {});
    const tenantId = body.tenantId || `tenant_${Date.now()}`;

    const out = args.tenants.upsertNew(tenantId);
    if (!out.created) return res.status(409).json({ ok: false, error: "tenant_exists", tenantId });

    return res.json({ ok: true, tenantId: out.tenantId, tenantKey: out.tenantKey });
  });

  r.post("/admin/tenants/rotate", async (req, res) => {
    const ak = requireAdminKey(req);
    if (!ak.ok) return res.status(ak.status).json({ ok: false, error: ak.error });

    const schema = z.object({ tenantId: z.string().min(3).max(64) });
    const body = schema.parse(req.body || {});
    const out = args.tenants.rotate(body.tenantId);
    if (!out.ok) return res.status(404).json({ ok: false, error: out.error });

    return res.json({ ok: true, tenantId: out.tenantId, tenantKey: out.tenantKey });
  });

  r.get("/admin/tenants", async (req, res) => {
    const ak = requireAdminKey(req);
    if (!ak.ok) return res.status(ak.status).json({ ok: false, error: ak.error });
    return res.json({ ok: true, tenants: args.tenants.list().map(t => ({ tenantId: t.tenantId, createdAt: t.createdAt, rotatedAt: t.rotatedAt })) });
  });

  // ---------------------------
  // (3) CSV export (proof/report)
  // ---------------------------
  r.get("/admin/export.csv", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).send(`error,${tk.error}\n`);

    const items = await args.store.listWorkItems(tenantId, { limit: 200, offset: 0 });

    const headers = [
      "id","tenantId","source","sender","subject","category","priority","status","slaSeconds","dueAt","createdAt","updatedAt"
    ];

    const lines = [headers.join(",")];
    for (const it of items) {
      const row = [
        it.id, it.tenantId, it.source, it.sender, it.subject,
        it.category, it.priority, it.status, it.slaSeconds, it.dueAt,
        it.createdAt, it.updatedAt
      ].map(csvEscape);
      lines.push(row.join(","));
    }

    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="workitems_${tenantId}.csv"`);
    res.send(lines.join("\n") + "\n");
  });

  // ---------------------------
  // Stats proof (kept)
  // ---------------------------
  r.get("/admin/stats", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const items = await args.store.listWorkItems(tenantId, { limit: 200, offset: 0 });

    const byStatus: Record<string, number> = {};
    const byPriority: Record<string, number> = {};
    const byCategory: Record<string, number> = {};

    for (const it of items) {
      byStatus[it.status] = (byStatus[it.status] || 0) + 1;
      byPriority[it.priority] = (byPriority[it.priority] || 0) + 1;
      byCategory[it.category] = (byCategory[it.category] || 0) + 1;
    }

    res.json({
      ok: true,
      tenantId,
      window: { latest: 200 },
      totals: { items: items.length },
      byStatus,
      byPriority,
      byCategory
    });
  });

  // ---------------------------
  // Slack outbound (kept)
  // ---------------------------
  r.post("/outbound/slack", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const webhook = (process.env.SLACK_WEBHOOK_URL || "").trim();
    if (!webhook) return res.status(400).json({ ok: false, error: "missing_slack_webhook_url" });

    const schema = z.object({
      text: z.string().min(1).max(4000).optional(),
      workItemId: z.string().min(1).optional()
    });

    const body = schema.parse(req.body || {});
    let text = body.text;

    if (!text && body.workItemId) {
      const item = await args.store.getWorkItem(tenantId, body.workItemId);
      if (!item) return res.status(404).json({ ok: false, error: "workitem_not_found" });
      text = `🛠️ IT Ticket\n• ${item.subject ?? "(no subject)"}\n• From: ${item.sender}\n• Priority: ${item.priority}\n• Due: ${item.dueAt}\n• Id: ${item.id}`;
    }

    if (!text) return res.status(400).json({ ok: false, error: "missing_text_or_workItemId" });

    const r2 = await fetch(webhook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text })
    });

    if (!r2.ok) {
      const t = await r2.text().catch(() => "");
      return res.status(502).json({ ok: false, error: "slack_failed", status: r2.status, body: t.slice(0, 200) });
    }

    res.json({ ok: true });
  });

  // ---------------------------
  // (2) Email outbound (SMTP)
  // ---------------------------
  r.post("/outbound/email", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const host = (process.env.SMTP_HOST || "").trim();
    const port = Number(process.env.SMTP_PORT || "587");
    const user = (process.env.SMTP_USER || "").trim();
    const pass = (process.env.SMTP_PASS || "").trim();
    const from = (process.env.EMAIL_FROM || "").trim();

    if (!host || !user || !pass || !from) {
      return res.status(400).json({ ok: false, error: "missing_smtp_env" });
    }

    const schema = z.object({
      to: z.string().email().optional(),
      subject: z.string().min(1).max(200).optional(),
      text: z.string().min(1).max(8000).optional(),
      workItemId: z.string().min(1).optional()
    });

    const body = schema.parse(req.body || {});
    const to = (body.to || process.env.EMAIL_TO || "").trim();
    if (!to) return res.status(400).json({ ok: false, error: "missing_to" });

    let subject = body.subject;
    let text = body.text;

    if ((!subject || !text) && body.workItemId) {
      const item = await args.store.getWorkItem(tenantId, body.workItemId);
      if (!item) return res.status(404).json({ ok: false, error: "workitem_not_found" });
      subject = subject || `[IT] ${item.subject ?? "New ticket"} (${item.priority})`;
      text = text || `Ticket: ${item.id}\nFrom: ${item.sender}\nPriority: ${item.priority}\nDue: ${item.dueAt}\n\nBody:\n${item.rawBody}`;
    }

    if (!subject || !text) return res.status(400).json({ ok: false, error: "missing_subject_or_text" });

    const transporter = nodemailer.createTransport({
      host,
      port,
      secure: port === 465,
      auth: { user, pass }
    });

    await transporter.sendMail({ from, to, subject, text });
    res.json({ ok: true });
  });

  return r;
}
