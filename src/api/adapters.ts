import { Router } from "express";
import { z } from "zod";
import multer from "multer";
import { Store } from "../store/store.js";
import { createAgent } from "../plugin/createAgent.js";
import { resendToInboundEvent } from "../adapters/email-resend.js";
import { whatsappCloudToInboundEvent } from "../adapters/whatsapp-cloud.js";
import { verifyResendWebhook } from "./verify-resend.js";
import { verifyWhatsAppSignature } from "./verify-whatsapp.js";
import type { RawBodyRequest } from "./raw-body.js";

/**
 * Adapter endpoints:
 * Transform provider payload -> InboundEvent -> agent.intake()
 * Hardening (optional):
 * - Resend signature via Svix headers
 * - WhatsApp signature via X-Hub-Signature-256
 * - SendGrid inbound parse multipart/form-data
 */

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

  // --- Resend webhook (JSON) ---
  // Requires raw body to verify signatures (optional)
  r.post("/email/resend", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);

    const v = verifyResendWebhook(req as RawBodyRequest);
    if (!v.ok) return res.status(400).json({ ok: false, error: v.error });

    const ev = resendToInboundEvent({ tenantId, body: req.body });
    const out = await agent.intake(ev);
    res.json(out);
  });

  // --- SendGrid inbound parse (multipart/form-data) ---
  // Twilio docs: inbound parse POSTs multipart/form-data.  [oai_citation:4‡Twilio](https://www.twilio.com/docs/sendgrid/for-developers/parsing-email/setting-up-the-inbound-parse-webhook?utm_source=chatgpt.com)
  r.post("/email/sendgrid", upload.any(), async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);

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
        // attachments info is in req.files (kept minimal in v1)
        attachments: Array.isArray((req as any).files) ? (req as any).files.map((f: any) => ({
          fieldname: f.fieldname, originalname: f.originalname, mimetype: f.mimetype, size: f.size
        })) : []
      },
      receivedAt: new Date().toISOString()
    });

    res.json(out);
  });

  // --- WhatsApp Cloud verify (GET) ---
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

    const v = verifyWhatsAppSignature(req as RawBodyRequest);
    if (!v.ok) return res.status(400).json({ ok: false, error: v.error });

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
