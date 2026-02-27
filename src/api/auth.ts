import { Router } from "express";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { upsertTenantRecord } from "../lib/tenant_registry";

type AuthOpts = {
  dataDir?: string;
  appBaseUrl?: string;
  emailFrom?: string;
};

type AuthTokenRecord = {
  tokenHash: string; // CHANGED: store hash instead of plain token
  email: string;
  createdAtUtc: string;
  expiresAtUtc: string;
  usedAtUtc?: string;
  ip?: string;
  ua?: string;
};

function nowIso() {
  return new Date().toISOString();
}

function safeMkdir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function readJson<T>(p: string, fallback: T): T {
  try {
    if (!fs.existsSync(p)) return fallback;
    return JSON.parse(fs.readFileSync(p, "utf8")) as T;
  } catch {
    return fallback;
  }
}

function writeJson(p: string, obj: unknown) {
  safeMkdir(path.dirname(p));
  fs.writeFileSync(p, JSON.stringify(obj, null, 2), "utf8");
}

function randToken(len = 32) {
  // url-safe
  return crypto.randomBytes(len).toString("base64url");
}

function randKey(len = 32) {
  // tenant key must be stable and url-safe
  return crypto.randomBytes(len).toString("base64url").slice(0, len);
}

function hashToken(token: string) {
  return crypto.createHash("sha256").update(token).digest("hex");
}

function constantTimeEq(a: string, b: string) {
  try {
    const ab = Buffer.from(a);
    const bb = Buffer.from(b);
    if (ab.length !== bb.length) return false;
    return crypto.timingSafeEqual(ab, bb);
  } catch {
    return false;
  }
}

function normalizeEmail(x: any) {
  const s = String(x || "").trim().toLowerCase();
  if (!s.includes("@")) return "";
  if (s.length > 200) return "";
  return s;
}

function allowlistOk(email: string) {
  const paid = String(process.env.PAID_MODE || "").toLowerCase();
  if (!(paid === "1" || paid === "true" || paid === "yes")) return true;

  const raw = String(process.env.ALLOWLIST_EMAILS || "").trim();
  if (!raw) return false;

  const list = raw
    .split(",")
    .map(s => s.trim().toLowerCase())
    .filter(Boolean);

  return list.some(e => constantTimeEq(e, email));
}

function outboxWrite(dataDirAbs: string, subject: string, body: string) {
  const outDir = path.join(dataDirAbs, "outbox");
  safeMkdir(outDir);
  const f = path.join(outDir, `mail_${Date.now()}.txt`);
  fs.writeFileSync(f, `SUBJECT: ${subject}\n\n${body}\n`, "utf8");
  return f;
}

function computeBaseUrl(req: any, explicit?: string) {
  if (explicit && String(explicit).trim()) return String(explicit).trim();
  const proto =
    String(req.headers?.["x-forwarded-proto"] || "") ||
    (req.socket?.encrypted ? "https" : "http");
  const host = String(req.headers?.["x-forwarded-host"] || req.headers?.host || "localhost");
  return `${proto}://${host}`;
}

function authStorePaths(dataDirAbs: string) {
  const dir = path.join(dataDirAbs, "auth");
  safeMkdir(dir);
  return {
    dir,
    tokensJson: path.join(dir, "tokens.json"),
  };
}

export function authRouter(opts?: AuthOpts) {
  const r = Router();

  const dataDirAbs = path.resolve(opts?.dataDir || process.env.DATA_DIR || "./data");
  const { tokensJson } = authStorePaths(dataDirAbs);

  // POST /api/auth/request-link  { email }
  r.post("/request-link", (req, res) => {
    const email = normalizeEmail(req.body?.email);
    if (!email) return res.status(400).json({ ok: false, error: "missing_email" });

    if (!allowlistOk(email)) {
      return res.status(403).json({ ok: false, error: "not_allowed" });
    }

    const ttlMin = Number(process.env.AUTH_TOKEN_TTL_MINUTES || 30);
    const token = randToken(24);
    const tokenHash = hashToken(token);
    const createdAtUtc = nowIso();
    const expiresAtUtc = new Date(Date.now() + ttlMin * 60_000).toISOString();

    const all = readJson<AuthTokenRecord[]>(tokensJson, []);
    all.unshift({
      tokenHash,
      email,
      createdAtUtc,
      expiresAtUtc,
      ip: String(req.ip || ""),
      ua: String(req.headers?.["user-agent"] || ""),
    });
    // Keep last 500
    writeJson(tokensJson, all.slice(0, 500));

    const baseUrl = computeBaseUrl(req, opts?.appBaseUrl || process.env.APP_BASE_URL);
    const verifyUrl = `${baseUrl}/api/auth/verify?token=${encodeURIComponent(token)}`;

    const subject = "Decision Cover — Your secure login link";
    const body =
`Hello,

Click to create your workspace + get your Tenant Key:

${verifyUrl}

This link expires in ${ttlMin} minutes.

— Decision Cover`;

    // In dev: write to outbox (works without SMTP)
    outboxWrite(dataDirAbs, subject, body);

    // If SMTP_URL exists, we *could* send later; for pilot keep outbox-only.
    return res.status(200).json({ ok: true });
  });

  // GET /api/auth/verify?token=...
  r.get("/verify", (req, res) => {
    const token = String((req.query as any)?.token || "").trim();
    if (!token) return res.status(400).send("missing_token");

    const all = readJson<AuthTokenRecord[]>(tokensJson, []);
    const h = hashToken(token);

    // Compare hashes
    const rec = all.find(x => x && x.tokenHash && constantTimeEq(x.tokenHash, h));
    if (!rec) return res.status(400).send("invalid_token");

    const now = Date.now();
    const exp = Date.parse(rec.expiresAtUtc || "");
    if (!Number.isFinite(exp) || now > exp) return res.status(400).send("expired_token");
    if (rec.usedAtUtc) return res.status(400).send("token_used");

    // Mark used
    rec.usedAtUtc = nowIso();
    writeJson(tokensJson, all);

    // Provision tenant
    const tenantId = `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
    const tenantKey = randKey(Number(process.env.TENANT_KEY_LEN || 32));

    // Store in registry (SSOT local)
    upsertTenantRecord(
      {
        tenantId,
        tenantKey,
        notes: `provisioned:${rec.email}`,
      },
      dataDirAbs
    );

    const baseUrl = computeBaseUrl(req, opts?.appBaseUrl || process.env.APP_BASE_URL);
    const dest = `${baseUrl}/ui/welcome?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;
    res.setHeader("Cache-Control", "no-store");
    return res.redirect(302, dest);
  });

  return r;
}
