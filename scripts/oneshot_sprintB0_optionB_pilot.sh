#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK"

echo "==> Sprint B0 (Option B) one-shot: auth verify + provisioning + welcome UI"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"
echo

backup() {
  local p="$1"
  if [ -f "$p" ]; then
    mkdir -p "$BAK/$(dirname "$p")"
    cp -v "$p" "$BAK/$p.bak" >/dev/null
  fi
}

# Backups
backup "src/api/auth.ts"
backup "src/server.ts"
backup "scripts/smoke-auth-provisioning.sh"

mkdir -p src/api src/ui scripts data/outbox data/auth

# -----------------------------
# 1) Write src/api/auth.ts (full file)
# -----------------------------
cat > src/api/auth.ts <<'TS'
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
  token: string;
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
    const createdAtUtc = nowIso();
    const expiresAtUtc = new Date(Date.now() + ttlMin * 60_000).toISOString();

    const all = readJson<AuthTokenRecord[]>(tokensJson, []);
    all.unshift({
      token,
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
    const rec = all.find(x => x && x.token && constantTimeEq(x.token, token));
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
TS

# -----------------------------
# 2) Write src/ui/welcome_route.ts
# -----------------------------
cat > src/ui/welcome_route.ts <<'TS'
import type { Express } from "express";

function esc(x: string) {
  return (x || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function mountWelcome(app: Express) {
  app.get("/ui/welcome", (req, res) => {
    const tenantId = String((req.query as any).tenantId || "");
    const k = String((req.query as any).k || "");

    const proto = String((req.headers["x-forwarded-proto"] as any) || ((req.socket as any).encrypted ? "https" : "http"));
    const host = String((req.headers["x-forwarded-host"] as any) || req.headers.host || "localhost");
    const baseUrl = `${proto}://${host}`;

    const qs = tenantId && k ? `?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}` : "";

    const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Welcome — Decision Cover</title>
<style>
  :root{color-scheme:dark}
  body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1200px 800px at 30% 20%, #2b1055 0%, #0b0b12 55%, #05070c 100%);color:#e5e7eb}
  .wrap{max-width:980px;margin:42px auto;padding:0 18px}
  .card{border:1px solid rgba(255,255,255,.10);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
  h1{font-size:22px;margin:0 0 6px}
  .muted{color:#9ca3af;font-size:13px}
  .row{display:flex;gap:10px;flex-wrap:wrap;margin-top:10px}
  .pill{border:1px solid rgba(255,255,255,.12);background:rgba(0,0,0,.20);border-radius:999px;padding:6px 10px;font-size:12px}
  a{color:#c4b5fd;text-decoration:none}
  pre{white-space:pre-wrap;word-break:break-word;background:rgba(0,0,0,.35);border:1px solid rgba(255,255,255,.10);padding:12px;border-radius:12px}
  code{font-family:ui-monospace,Menlo,Monaco,Consolas,monospace;font-size:12px}
  .btn{display:inline-block;margin-top:10px;border:1px solid rgba(255,255,255,.18);background:rgba(139,92,246,.18);padding:10px 12px;border-radius:12px}
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Welcome — your workspace is ready ✅</h1>
      <div class="muted">This page is your “client-proof kit”: webhook → tickets → CSV export → evidence ZIP.</div>

      <div class="row">
        <div class="pill">baseUrl: <b>${esc(baseUrl)}</b></div>
        <div class="pill">tenantId: <b>${esc(tenantId || "—")}</b></div>
        <div class="pill">k: <b>${esc(k ? (k.slice(0,10)+"…") : "—")}</b></div>
      </div>

      <div class="muted" style="margin-top:14px">1) Setup (copy/paste for Zapier)</div>
      <pre><code>${esc(baseUrl)}/ui/setup${esc(qs)}</code></pre>
      <a class="btn" href="/ui/setup${qs}">Open Setup</a>

      <div class="muted" style="margin-top:14px">2) Tickets UI</div>
      <pre><code>${esc(baseUrl)}/ui/tickets${esc(qs)}</code></pre>

      <div class="muted" style="margin-top:14px">3) Export CSV</div>
      <pre><code>${esc(baseUrl)}/ui/export.csv${esc(qs)}</code></pre>

      <div class="muted" style="margin-top:14px">4) Evidence ZIP</div>
      <pre><code>${esc(baseUrl)}/ui/evidence.zip${esc(qs)}</code></pre>

      <div class="muted" style="margin-top:14px">Webhook endpoint</div>
      <pre><code>POST ${esc(baseUrl)}/api/webhook/intake
Content-Type: application/json</code></pre>

      <div class="muted" style="margin-top:14px">Done. If you lose this page, request a new link.</div>
    </div>
  </div>
</body>
</html>`;

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.setHeader("Cache-Control", "no-store");
    return res.status(200).send(html);
  });
}
TS

# -----------------------------
# 3) Patch src/server.ts to mount /api/auth + welcome route (safe Node patch)
# -----------------------------
cat > /tmp/patch_server_optionB.mjs <<'NODE'
import fs from "node:fs";

const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

// Ensure imports
if (!s.includes('import { authRouter } from "./api/auth"') && !s.includes('from "./api/auth"')) {
  // add near top
  const lines = s.split("\n");
  const insertAt = Math.min(5, lines.length);
  lines.splice(insertAt, 0, 'import { authRouter } from "./api/auth";');
  s = lines.join("\n");
}
if (!s.includes('from "./ui/welcome_route')) {
  const lines = s.split("\n");
  const insertAt = Math.min(6, lines.length);
  lines.splice(insertAt, 0, 'import { mountWelcome } from "./ui/welcome_route";');
  s = lines.join("\n");
}

// Mount auth AFTER express.json and BEFORE makeRoutes usage
// We’ll inject after the line containing: app.use(express.json(
const marker = 'app.use(express.json';
const idxJson = s.indexOf(marker);

if (idxJson >= 0 && !s.includes('app.use("/api/auth", authRouter')) {
  const lineStart = s.lastIndexOf("\n", idxJson);
  const lineEnd = s.indexOf("\n", idxJson);
  const afterLine = lineEnd >= 0 ? lineEnd + 1 : s.length;

  const inject =
`  // Auth (Option B)
  app.use("/api/auth", authRouter({
    dataDir: process.env.DATA_DIR || "./data",
    appBaseUrl: process.env.APP_BASE_URL || undefined,
    emailFrom: process.env.EMAIL_FROM || "Decision Cover <no-reply@local>",
  }));

`;

  s = s.slice(0, afterLine) + inject + s.slice(afterLine);
}

// Mount welcome UI once (anywhere after app is created)
if (!s.includes("mountWelcome(app")) {
  // inject after "mountUnifiedTheme(app);" line if exists, else after app creation
  let at = s.indexOf("mountUnifiedTheme(app);");
  if (at < 0) at = s.indexOf("const app = express()");
  if (at < 0) at = s.indexOf("const app = express()");
  if (at < 0) at = s.indexOf("const app = express()");
  // find end of line
  const lineEnd = s.indexOf("\n", at);
  const ins = (lineEnd >= 0 ? lineEnd + 1 : s.length);
  s = s.slice(0, ins) + `  mountWelcome(app as any);\n` + s.slice(ins);
}

fs.writeFileSync(p, s, "utf8");
console.log("OK: patched src/server.ts (imports + mount /api/auth + mountWelcome)");
NODE

node /tmp/patch_server_optionB.mjs

# -----------------------------
# 4) Write/overwrite scripts/smoke-auth-provisioning.sh (improved)
# -----------------------------
cat > scripts/smoke-auth-provisioning.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail

# auto-load .env.local for local runs (no secrets printed)
if [ -f "./.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  source "./.env.local" || true
  set +a
fi

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
EMAIL="${EMAIL:-test+agency@local.dev}"
DATA_DIR="${DATA_DIR:-./data}"

echo "==> SMOKE Auth Provisioning (request-link -> outbox -> verify -> welcome)"
echo "==> BASE_URL = $BASE_URL"
echo "==> EMAIL    = $EMAIL"
echo

code="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/health" || true)"
if [ "$code" != "200" ]; then
  echo "FAIL: /health expected 200, got $code" >&2
  exit 1
fi
echo "OK: /health"

# Request link (should 200)
code="$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/api/auth/request-link" \
  -H "content-type: application/json" \
  --data "{\"email\":\"$EMAIL\"}" || true)"

echo "request-link => HTTP $code"
if [ "$code" != "200" ]; then
  echo "FAIL: expected 200" >&2
  exit 1
fi

# Find newest outbox mail and extract verify URL
OUTDIR="$DATA_DIR/outbox"
if [ ! -d "$OUTDIR" ]; then
  echo "FAIL: outbox dir missing: $OUTDIR" >&2
  exit 1
fi

latest="$(ls -1t "$OUTDIR"/mail_*.txt 2>/dev/null | head -n 1 || true)"
if [ -z "$latest" ]; then
  echo "FAIL: no outbox mail_*.txt found in $OUTDIR" >&2
  exit 1
fi

verify="$(rg -n "http.*?/api/auth/verify\\?token=" "$latest" | head -n 1 | sed -E 's/^[0-9]+://' | tr -d '\r' || true)"
if [ -z "$verify" ]; then
  echo "FAIL: could not extract verify URL from $latest" >&2
  exit 1
fi

echo "OK: outbox mail => $latest"
echo "OK: verify URL  => (hidden)"
echo

# Call verify and ensure redirect to /ui/welcome
hdr="$(mktemp)"
body="$(mktemp)"
curl -sS -D "$hdr" -o "$body" -i "$verify" >/dev/null || true

loc="$(rg -n "^Location:" "$hdr" | head -n 1 | sed -E 's/^Location:\s*//' | tr -d '\r' || true)"
status="$(head -n 1 "$hdr" | awk '{print $2}' || true)"

if [ "$status" != "302" ]; then
  echo "FAIL: verify expected 302, got $status" >&2
  cat "$hdr" | head -n 30 >&2
  exit 1
fi

if ! echo "$loc" | rg -q "/ui/welcome\\?tenantId="; then
  echo "FAIL: verify redirect location unexpected: $loc" >&2
  exit 1
fi

echo "OK ✅ verify redirect => /ui/welcome"
rm -f "$hdr" "$body"

echo "OK ✅ Auth provisioning flow (pilot) works"
SH2
chmod +x scripts/smoke-auth-provisioning.sh

# -----------------------------
# 5) Final checks
# -----------------------------
echo
echo "==> typecheck"
pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "==> SMOKE tenant auth"
./scripts/smoke-tenant-auth.sh

echo
echo "==> E2E Phase48"
./scripts/e2e-phase48.sh

echo
echo "==> SMOKE auth provisioning"
./scripts/smoke-auth-provisioning.sh

echo
echo "OK ✅ Sprint B0 applied"
echo "Backups: $BAK"
echo
echo "NEXT: open http://127.0.0.1:7090/ui/welcome (via emailed link) and sell the pilot."
