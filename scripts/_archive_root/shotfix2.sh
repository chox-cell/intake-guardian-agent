#!/usr/bin/env bash
set -euo pipefail

cd "${ROOT:-$HOME/Projects/intake-guardian-agent}"

echo "==> ShotFix v2: fix workItem scope + mailer null"

ts="$(date +%Y%m%d_%H%M%S)"
BK="__bak_shotfix2_${ts}"
mkdir -p "$BK"

backup() { [ -f "$1" ] && mkdir -p "$BK/$(dirname "$1")" && cp -v "$1" "$BK/$1" >/dev/null || true; }
backup src/api/adapters.ts
backup src/server.ts

echo "==> [1] Patch src/api/adapters.ts (remove broken block + add res.json interceptor)"
node - <<'NODE'
const fs = require("fs");

const p = "src/api/adapters.ts";
let s = fs.readFileSync(p, "utf8");

// 1) Remove any previously injected broken receipt block (workItem out of scope)
s = s.replace(
  /\/\/ Non-blocking receipt email \(Resend\)[\s\S]*?\n\s*\}\s*catch\s*\(e\)\s*\{\}\s*\n/g,
  ""
);

// 2) Insert a safe interceptor INSIDE the SendGrid handler
// We look for the first occurrence of the SendGrid route handler line.
const candidates = [
  '"/email/sendgrid"',
  "'/email/sendgrid'",
  '"/adapters/email/sendgrid"',
  "'/adapters/email/sendgrid'"
];

let idx = -1;
for (const c of candidates) {
  idx = s.indexOf(c);
  if (idx !== -1) break;
}
if (idx === -1) {
  console.error("❌ Could not find sendgrid route marker in adapters.ts");
  process.exit(1);
}

// Find the handler start `async (req, res) => {` after that marker
const after = s.slice(idx);
const m = after.match(/async\s*\(\s*req\s*,\s*res\s*\)\s*=>\s*\{/);
if (!m) {
  console.error("❌ Could not find async(req,res)=>{ handler near sendgrid route");
  process.exit(1);
}

const handlerPos = idx + m.index + m[0].length;

// Avoid double-insert
if (s.includes("res.json = ((payload: any) =>")) {
  fs.writeFileSync(p, s);
  console.log("✅ Interceptor already present, kept as-is:", p);
  process.exit(0);
}

const interceptor = `
    // Receipt mail interceptor (Resend) — reads payload.workItem safely
    const __json = res.json.bind(res);
    res.json = ((payload: any) => {
      try {
        const wi = payload?.workItem;
        const tenantId =
          (wi?.tenantId as string) ||
          (req.query?.tenantId as string) ||
          (payload?.tenantId as string);

        const sender = wi?.sender as string | undefined;

        if (args.mailer && args.shares && wi && sender && tenantId) {
          const token = args.shares.create(tenantId);
          const base = (process.env.PUBLIC_BASE_URL || "http://127.0.0.1:7090").replace(/\\/+$/,"");
          const shareUrl = base + "/ui/share/" + token;

          args.mailer.sendReceipt({
            to: sender,
            subject: "Ticket created: " + (wi.subject || wi.id),
            ticketId: wi.id,
            tenantId,
            dueAtISO: wi.dueAt,
            slaSeconds: wi.slaSeconds,
            priority: wi.priority,
            shareUrl
          }).catch(() => {});
        }
      } catch (e) {}
      return __json(payload);
    }) as any;
`;

// Insert interceptor right after handler opening brace
s = s.slice(0, handlerPos) + interceptor + s.slice(handlerPos);

fs.writeFileSync(p, s);
console.log("✅ Patched", p);
NODE

echo "==> [2] Patch src/server.ts (mailer null -> undefined, remove duplicate new ResendMailer blocks)"
node - <<'NODE'
const fs = require("fs");

const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

// Remove any direct `const mailer = new ResendMailer({ ... });` blocks (keep only computed one)
s = s.replace(/const\s+mailer\s*=\s*new\s+ResendMailer\s*\(\{\s*[\s\S]*?\}\);\s*\n/g, "");

// Convert `: null` to `: undefined` for mailer computed assignment
s = s.replace(/:\s*null\s*;/g, ": undefined;");

// Also convert `const mailer = (...)? ... : null;` to undefined if present
s = s.replace(/\?\s*new\s+ResendMailer\([\s\S]*?\)\s*:\s*null/g, (m) => m.replace(": null", ": undefined"));

fs.writeFileSync(p, s);
console.log("✅ Patched", p);
NODE

echo "==> [3] Typecheck"
pnpm lint:types

echo "==> [4] Commit"
git add src/api/adapters.ts src/server.ts
git commit -m "fix(resend): intercept res.json to send receipt + mailer undefined" || true

echo
echo "✅ Done. Now restart server:"
echo "  pnpm dev"
