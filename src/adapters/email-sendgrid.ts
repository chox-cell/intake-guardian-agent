import { z } from "zod";
import { InboundEvent } from "../types/contracts.js";

/**
 * SendGrid Inbound Parse عادة يرسل form-encoded.
 * هنا نسمح JSON أيضًا (للتجارب) عبر endpoint منفصل.
 */
const SendGridInboundJson = z.object({
  from: z.string().optional(),
  subject: z.string().optional(),
  text: z.string().optional(),
  html: z.string().optional(),
  headers: z.any().optional()
}).passthrough();

export function sendgridToInboundEvent(args: {
  tenantId: string;
  body: unknown;
}): InboundEvent {
  const p = SendGridInboundJson.parse(args.body);

  const from = (p.from ?? "").toString().trim();
  const subject = (p.subject ?? "").toString().trim();
  const text = (p.text ?? "").toString();
  const html = (p.html ?? "").toString();

  const content = (text && text.trim().length > 0) ? text : (html ? stripHtml(html) : "");

  return {
    tenantId: args.tenantId,
    source: "email",
    sender: from || "unknown@unknown",
    subject: subject || undefined,
    body: content || "(empty)",
    meta: {
      provider: "sendgrid",
      raw: safeMeta(p)
    },
    receivedAt: new Date().toISOString()
  };
}

function stripHtml(html: string): string {
  return html.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
}

function safeMeta(p: any) {
  return {
    from: p.from,
    subject: p.subject
  };
}
