import fs from "node:fs";
import path from "node:path";
import nodemailer from "nodemailer";

function resolveDataDir() {
  const d = process.env.DATA_DIR || "./data";
  return path.resolve(process.cwd(), d);
}

export type SendEmailInput = {
  to: string;
  subject: string;
  text: string;
};

export async function sendEmail(input: SendEmailInput): Promise<{ ok: true; mode: string } | { ok: false; error: string }> {
  const SMTP_URL = process.env.SMTP_URL || "";
  const FROM = process.env.EMAIL_FROM || "Decision Cover <no-reply@local>";

  // PROD-ish mode: SMTP configured
  if (SMTP_URL) {
    try {
      const transport = nodemailer.createTransport(SMTP_URL);
      await transport.sendMail({ from: FROM, to: input.to, subject: input.subject, text: input.text });
      return { ok: true, mode: "smtp" };
    } catch (e: any) {
      return { ok: false, error: String(e?.message || e) };
    }
  }

  // DEV mode: write to outbox file (no secrets, no SMTP)
  try {
    const abs = resolveDataDir();
    const outDir = path.join(abs, "outbox");
    fs.mkdirSync(outDir, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const fn = path.join(outDir, `email_${stamp}.txt`);
    fs.writeFileSync(fn, `TO: ${input.to}\nSUBJECT: ${input.subject}\n\n${input.text}\n`);
    return { ok: true, mode: "outbox" };
  } catch (e: any) {
    return { ok: false, error: String(e?.message || e) };
  }
}
