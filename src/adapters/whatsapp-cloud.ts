import { z } from "zod";
import { InboundEvent } from "../types/contracts.js";

/**
 * WhatsApp Cloud API Webhook (Meta) — الحد الأدنى الذي نحتاجه:
 * - sender (wa_id)
 * - message text
 */
const WABody = z.object({
  entry: z.array(z.object({
    changes: z.array(z.object({
      value: z.object({
        messages: z.array(z.object({
          from: z.string(),
          id: z.string().optional(),
          timestamp: z.string().optional(),
          text: z.object({
            body: z.string()
          }).optional(),
          type: z.string().optional()
        })).optional(),
        contacts: z.array(z.any()).optional(),
        metadata: z.any().optional()
      }).passthrough()
    }))
  }))
}).passthrough();

export function whatsappCloudToInboundEvent(args: {
  tenantId: string;
  body: unknown;
}): InboundEvent | null {
  const p = WABody.parse(args.body);
  const msg = p.entry?.[0]?.changes?.[0]?.value?.messages?.[0];
  if (!msg) return null;

  const sender = msg.from;
  const text = msg.text?.body ?? "";

  return {
    tenantId: args.tenantId,
    source: "whatsapp",
    sender,
    subject: undefined,
    body: text || "(empty)",
    meta: {
      provider: "whatsapp_cloud",
      messageId: msg.id,
      timestamp: msg.timestamp
    },
    receivedAt: new Date().toISOString()
  };
}
