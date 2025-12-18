import { Router } from "express";
import { z } from "zod";
import multer from "multer";
import { Store } from "../store/store.js";
import { createAgent } from "../plugin/createAgent.js";
import { resendToInboundEvent } from "../adapters/email-resend.js";
import { whatsappCloudToInboundEvent } from "../adapters/whatsapp-cloud.js";
import { verifyResendWebhook } from "./verify-resend.js";
import { verifyWhatsAppSignature, verifyWhatsAppMessageAge } from "./verify-whatsapp.js";
import type { RawBodyRequest } from "./raw-body.js";
import { makeRateLimiter } from "./rate-limit.js";
import { requireTenantKey } from "./tenant-key.js";

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 10 * 1024 * 1024 } });

export function makeAdapterRoutes(args: {
  store: Store;
  presetId: string;
  dedupeWindowSeconds: number;
  waVerifyToken?: string;
}) {
  const r = Router();
  const agent = createAgent({
    store: args.store,
    presetId: args.presetId,
    dedupeWindowSeconds: args.dedupeWindowSeconds
  });

  // Global rate-limit for adapters
  r.use(makeRateLimiter());

  // --- Resend webhook (JSON) ---
  r.post("/email/resend", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req, tenantId);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const v = verifyResendWebhook(req as RawBodyRequest);
    if (!v.ok) return res.status(401).json({ ok: false, error: v.error });

    const ev = resendToInboundEvent({ tenantId, body: req.body });
    const out = await agent.intake(ev);
    res.json(out);
  });

  // --- SendGrid inbound parse (multipart/form-data) ---
  r.post("/email/sendgrid", upload.any(), async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req, tenantId);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const body = req.body || {};
    const from = String(body.from || "").trim();
    const subject = String(body.subject || "").trim();
    const text = String(body.text || "").trim();
    const html = String(body.html || "").trim();
    const content = text.length ? text : (html ? stripHtml(html) : "(empty)");

    const out = await agent.intake({
      tenantId,
      source: "email",
      sender: from || "unknown@unknown",
      subject: subject || undefined,
      body: content,
      meta: {
        provider: "sendgrid",
        attachments: Array.isArray((req as any).files)
          ? (req as any).files.map((f: any) => ({
              fieldname: f.fieldname,
              originalname: f.originalname,
              mimetype: f.mimetype,
              size: f.size
            }))
          : []
      },
      receivedAt: new Date().toISOString()
    });

    res.json(out);
  });

  // --- WhatsApp Cloud verify (GET) ---
  // NOTE: Meta verification request won't include x-tenant-key; allow GET verify without tenant key.
  r.get("/whatsapp/cloud", async (req, res) => {
    const mode = String(req.query["hub.mode"] || "");
    const token = String(req.query["hub.verify_token"] || "");
    const challenge = String(req.query["hub.challenge"] || "");

    if (mode === "subscribe" && args.waVerifyToken && token === args.waVerifyToken) {
      return res.status(200).send(challenge);
    }
    return res.status(403).send("forbidden");
  });

  // --- WhatsApp Cloud messages (POST) ---
  r.post("/whatsapp/cloud", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req, tenantId);
    if (!tk.ok) return res.status(tk.status).json({ ok: false, error: tk.error });

    const sig = verifyWhatsAppSignature(req as RawBodyRequest);
    if (!sig.ok) return res.status(401).json({ ok: false, error: sig.error });

    const age = verifyWhatsAppMessageAge(req.body);
    if (!age.ok) return res.status(400).json({ ok: false, error: age.error });

    const ev = whatsappCloudToInboundEvent({ tenantId, body: req.body });
    if (!ev) return res.json({ ok: true, ignored: true });

    const out = await agent.intake(ev);
    res.json(out);
  });

  return r;
}

function stripHtml(html: string): string {
  return html.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
}
