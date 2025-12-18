import { z } from "zod";
import { InboundEvent } from "../types/contracts.js";

const ResendInbound = z.object({
  type: z.string().optional(),
  created_at: z.string().optional(),
  data: z.object({
    from: z.string().optional(),
    to: z.array(z.string()).optional(),
    subject: z.string().optional(),
    text: z.string().optional(),
    html: z.string().optional(),
    headers: z.any().optional()
  }).passthrough()
}).passthrough();

export function resendToInboundEvent(args: {
  tenantId: string;
  body: unknown;
}): InboundEvent {
  const p = ResendInbound.parse(args.body);

  const from = (p.data?.from ?? "").toString().trim();
  const subject = (p.data?.subject ?? "").toString().trim();
  const text = (p.data?.text ?? "").toString();
  const html = (p.data?.html ?? "").toString();

  const content = (text && text.trim().length > 0) ? text : (html ? stripHtml(html) : "");

  return {
    tenantId: args.tenantId,
    source: "email",
    sender: from || "unknown@unknown",
    subject: subject || undefined,
    body: content || "(empty)",
    meta: {
      provider: "resend",
      raw: safeMeta(p)
    },
    receivedAt: new Date().toISOString()
  };
}

function stripHtml(html: string): string {
  return html.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
}

function safeMeta(p: any) {
  // avoid storing huge raw blobs
  const { data, ...rest } = p || {};
  return {
    ...rest,
    data: {
      from: data?.from,
      to: data?.to,
      subject: data?.subject
    }
  };
}
