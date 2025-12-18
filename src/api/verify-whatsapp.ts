import crypto from "crypto";
import type { RawBodyRequest } from "./raw-body.js";

export function verifyWhatsAppSignature(req: RawBodyRequest): { ok: true } | { ok: false; error: string } {
  const secret = process.env.WA_APP_SECRET;
  if (!secret) return { ok: true }; // optional

  const header = req.header("x-hub-signature-256") || req.header("X-Hub-Signature-256") || "";
  const raw = req.rawBody || Buffer.from("");

  if (!header.startsWith("sha256=") || raw.length === 0) {
    return { ok: false, error: "missing_signature_or_raw_body" };
  }

  const expected = "sha256=" + crypto.createHmac("sha256", secret).update(raw).digest("hex");

  // timing-safe compare
  const a = Buffer.from(expected);
  const b = Buffer.from(header);
  if (a.length !== b.length) return { ok: false, error: "invalid_whatsapp_signature" };

  const ok = crypto.timingSafeEqual(a, b);
  return ok ? { ok: true } : { ok: false, error: "invalid_whatsapp_signature" };
}
