import { Router } from "express";
import { z } from "zod";
import { Store } from "../store/store.js";
import { createAgent } from "../plugin/createAgent.js";
import { resendToInboundEvent } from "../adapters/email-resend.js";
import { sendgridToInboundEvent } from "../adapters/email-sendgrid.js";
import { whatsappCloudToInboundEvent } from "../adapters/whatsapp-cloud.js";

/**
 * NOTE: هذه endpoints "Adapter-only".
 * لا تغيّر الـ Core ولا الـ SSOT. فقط تحول payload إلى InboundEvent ثم تمرره للـ Agent.
 */
export function makeAdapterRoutes(args: {
  store: Store;
  presetId: string;
  dedupeWindowSeconds: number;

  // WhatsApp verify (GET)
  waVerifyToken?: string;
}) {
  const r = Router();
  const agent = createAgent({
    store: args.store,
    presetId: args.presetId,
    dedupeWindowSeconds: args.dedupeWindowSeconds
  });

  // --- Email: Resend webhook (JSON) ---
  r.post("/email/resend", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const ev = resendToInboundEvent({ tenantId, body: req.body });
    const out = await agent.intake(ev);
    res.json(out);
  });

  // --- Email: SendGrid inbound parse (JSON for now) ---
  // (لو أردت form-data لاحقاً نضيف middleware، لكن v1 يكفي JSON للاختبار)
  r.post("/email/sendgrid", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const ev = sendgridToInboundEvent({ tenantId, body: req.body });
    const out = await agent.intake(ev);
    res.json(out);
  });

  // --- WhatsApp Cloud verify (GET) ---
  // Meta expects: hub.mode, hub.verify_token, hub.challenge
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
    const ev = whatsappCloudToInboundEvent({ tenantId, body: req.body });

    // WhatsApp may send status updates without messages.
    if (!ev) return res.json({ ok: true, ignored: true });

    const out = await agent.intake(ev);
    res.json(out);
  });

  return r;
}
