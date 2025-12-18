import crypto from "crypto";

export function fingerprintOf(args: {
  tenantId: string;
  sender: string;
  normalizedBody: string;
  presetId: string;
}): string {
  const raw = `${args.tenantId}|${args.sender}|${args.presetId}|${args.normalizedBody}`;
  return crypto.createHash("sha256").update(raw).digest("hex");
}
