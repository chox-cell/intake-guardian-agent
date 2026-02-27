#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$HOME/Projects/intake-guardian-agent}"
cd "$ROOT"

echo "==> OneShot FIX: Resend compile errors (adapters + server)"

ts="$(date +%Y%m%d_%H%M%S)"
BK="__bak_fix_resend_${ts}"
mkdir -p "$BK"

backup() { [ -f "$1" ] && mkdir -p "$BK/$(dirname "$1")" && cp -v "$1" "$BK/$1" >/dev/null || true; }

backup src/api/adapters.ts
backup src/server.ts

echo "==> [1] Patch src/api/adapters.ts (types + inject receipt inside scope)"
node - <<'NODE'
const fs = require("fs");
const p = "src/api/adapters.ts";
if (!fs.existsSync(p)) { console.error("missing", p); process.exit(1); }
let s = fs.readFileSync(p, "utf8");

// Ensure imports for ShareStore type (safe, type-only)
if (!s.includes('from "../share/store.js"') && !s.includes("from '../share/store.js'")) {
  // Put near other imports
  s = s.replace(/(import[\s\S]*?\n)\n/, (m)=> m + `import type { ShareStore } from "../share/store.js";\n\n`);
}

// Ensure args type has shares?: ShareStore and mailer can be undefined (no null)
if (!s.includes("shares?:")) {
  // Find the args type block in makeAdapterRoutes signature
  // We patch the FIRST occurrence of "makeAdapterRoutes(args: {"
  s = s.replace(
    /export function makeAdapterRoutes\(\s*args:\s*\{([\s\S]*?)\}\s*\)\s*\{/,
    (m, inner) => {
      if (inner.includes("shares?:")) return m;
      // inject near mailer/publicBaseUrl if present
      if (inner.includes("mailer?:")) {
        inner = inner.replace(/mailer\?\:\s*ResendMailer\s*;?/g, (mm)=> mm + `\n  shares?: ShareStore;`);
      } else {
        inner = inner + `\n  shares?: ShareStore;\n  mailer?: any;\n`;
      }
      // If mailer typed as ResendMailer already, keep, else fine.
      return `export function makeAdapterRoutes(args: {${inner}\n}) {`;
    }
  );
}

// Remove any previously injected broken block that references workItem out of scope
s = s.replace(
  /\/\/ Non-blocking receipt email \(Resend\)[\s\S]*?\n\s*\}\s*catch\s*\(e\)\s*\{\}\s*\n/g,
  ""
);

// Now inject receipt *inside* the sendgrid handler, right before the response is returned.
// We target the common shape: `return res.json({ ok: true, duplicated, workItem ... })`
const needle = "return res.json({ ok: true";
if (!s.includes("args.shares.create") && s.includes(needle)) {
  s = s.replace(needle, `
    // Non-blocking receipt email (Resend) - inside handler scope
    try {
      if (args.mailer && args.shares && workItem && workItem.sender) {
        const token = args.shares.create(tenantId);
        const base = (process.env.PUBLIC_BASE_URL || "http://127.0.0.1:7090").replace(/\\/+$/,"");
        const shareUrl = base + "/ui/share/" + token;

        args.mailer.sendReceipt({
          to: workItem.sender,
          subject: "Ticket created: " + (workItem.subject || workItem.id),
          ticketId: workItem.id,
          tenantId,
          dueAtISO: workItem.dueAt,
          slaSeconds: workItem.slaSeconds,
          priority: workItem.priority,
          shareUrl
        }).catch(()=>{});
      }
    } catch (e) {}

${needle}`);
}

fs.writeFileSync(p, s);
console.log("✅ Patched", p);
NODE

echo "==> [2] Patch src/server.ts (single mailer + no null + pass shares)"
node - <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
if (!fs.existsSync(p)) { console.error("missing", p); process.exit(1); }
let s = fs.readFileSync(p, "utf8");

// Remove any duplicated `const mailer = new ResendMailer({ ... });` blocks (keep only computed one)
s = s.replace(/const\s+mailer\s*=\s*new\s+ResendMailer\s*\(\{\s*[\s\S]*?\}\);\s*\n/g, "");

// Ensure imports exist
if (!s.includes('from "./share/store.js"') && !s.includes("from './share/store.js'")) {
  s = s.replace(/from "\.\/api\/ui\.js";\n/, (m)=> m + `import { ShareStore } from "./share/store.js";\n`);
}
if (!s.includes('from "./lib/resend.js"') && !s.includes("from './lib/resend.js'")) {
  // put after share import if exists, else after ui import
  if (s.includes('from "./share/store.js";\n')) {
    s = s.replace(/from "\.\/share\/store\.js";\n/, (m)=> m + `import { ResendMailer } from "./lib/resend.js";\n`);
  } else {
    s = s.replace(/from "\.\/api\/ui\.js";\n/, (m)=> m + `import { ResendMailer } from "./lib/resend.js";\n`);
  }
}

// Ensure env vars exist (idempotent)
if (!s.includes("RESEND_API_KEY")) {
  s = s.replace(/const\s+PORT\s*=.*\n/, (m)=> m + `const RESEND_API_KEY = (process.env.RESEND_API_KEY || "").trim();\nconst RESEND_FROM = (process.env.RESEND_FROM || "").trim();\nconst PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || "http://127.0.0.1:7090").trim();\nconst RESEND_DRY_RUN = (process.env.RESEND_DRY_RUN || "0").trim() === "1";\n`);
}

// Ensure shares + single computed mailer (mailer is undefined when not configured)
if (!s.includes("const shares = new ShareStore")) {
  // insert after store init line: `const store = new FileStore(...);`
  s = s.replace(/const\s+store\s*=\s*new\s+FileStore\([^\n]*\);\s*\n/, (m)=> m + `
const shares = new ShareStore();
const mailer: ResendMailer | undefined =
  (RESEND_API_KEY && RESEND_FROM)
    ? new ResendMailer({ apiKey: RESEND_API_KEY, from: RESEND_FROM, publicBaseUrl: PUBLIC_BASE_URL, dryRun: RESEND_DRY_RUN })
    : undefined;
`);
} else {
  // If shares exists but mailer computed missing, ensure one computed mailer is present
  if (!s.includes("const mailer: ResendMailer") && !s.includes("const mailer = (RESEND_API_KEY")) {
    s = s.replace(/const\s+shares\s*=\s*new\s+ShareStore\(\);\s*\n/, (m)=> m + `
const mailer: ResendMailer | undefined =
  (RESEND_API_KEY && RESEND_FROM)
    ? new ResendMailer({ apiKey: RESEND_API_KEY, from: RESEND_FROM, publicBaseUrl: PUBLIC_BASE_URL, dryRun: RESEND_DRY_RUN })
    : undefined;
`);
  }
}

// Pass shares+mailer into makeAdapterRoutes
// Ensure adapters mount includes tenants + shares + mailer
s = s.replace(/makeAdapterRoutes\(\{\s*([\s\S]*?)\}\)/g, (m, inner) => {
  // Only patch the adapters call (must contain presetId or waVerifyToken)
  if (!inner.includes("presetId") && !inner.includes("waVerifyToken") && !inner.includes("dedupeWindowSeconds")) return m;

  // Ensure tenants exists
  if (!inner.includes("tenants")) inner = inner.replace(/store,\s*\n/, "store,\n      tenants,\n");
  // Ensure shares exists
  if (!inner.includes("shares")) inner = inner.replace(/tenants,\s*\n/, "tenants,\n      shares,\n");
  // Ensure mailer exists
  if (!inner.includes("mailer")) inner = inner.replace(/shares,\s*\n/, "shares,\n      mailer,\n");
  return `makeAdapterRoutes({ ${inner} })`;
});

// Pass shares into UI route if ui supports it (safe even if ignored)
s = s.replace(/makeUiRoutes\(\{\s*store\s*,\s*tenants\s*\}\)/g, "makeUiRoutes({ store, tenants, shares })");

fs.writeFileSync(p, s);
console.log("✅ Patched", p);
NODE

echo "==> [3] Typecheck"
pnpm lint:types

echo "==> [4] Commit"
git add src/api/adapters.ts src/server.ts
git commit -m "fix(resend): adapters shares typing + receipt scope + single mailer in server" || true

echo
echo "✅ FIX DONE"
echo "Next:"
echo "  1) restart server: pnpm dev"
echo "  2) re-run: pnpm lint:types"
NODE
