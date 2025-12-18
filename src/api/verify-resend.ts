import { Webhook } from "svix";
import type { RawBodyRequest } from "./raw-body.js";

export function verifyResendWebhook(req: RawBodyRequest): { ok: true } | { ok: false; error: string } {
  const secret = process.env.RESEND_WEBHOOK_SECRET;
  if (!secret) return { ok: true }; // optional

  const id = req.header("svix-id") || "";
  const ts = req.header("svix-timestamp") || "";
  const sig = req.header("svix-signature") || "";
  const payload = (req.rawBody ? req.rawBody.toString("utf8") : "");

  if (!id || !ts || !sig || !payload) {
    return { ok: false, error: "missing_svix_headers_or_raw_body" };
  }

  try {
    const wh = new Webhook(secret);
    // throws if invalid
    wh.verify(payload, {
      "svix-id": id,
      "svix-timestamp": ts,
      "svix-signature": sig
    });
    return { ok: true };
  } catch {
    return { ok: false, error: "invalid_resend_signature" };
  }
}
