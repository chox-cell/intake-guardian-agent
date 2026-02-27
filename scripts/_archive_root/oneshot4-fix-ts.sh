#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$HOME/Projects/intake-guardian-agent}"
cd "$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
echo "==> OneShot4 FIX @ $ROOT ($ts)"

backup() {
  local p="$1"
  if [ -f "$p" ]; then
    cp -v "$p" "${p}.bak.${ts}" >/dev/null
    echo "  backup: $p -> ${p}.bak.${ts}"
  fi
}

backup src/lib/resend.ts
backup src/api/adapters.ts
backup src/api/outbound.ts
backup src/server.ts

mkdir -p src/lib src/api

echo "==> [1] Patch ResendMailer: add sendTicketReceipt() alias (compat)"
node - <<'NODE'
const fs = require("fs");
const p = "src/lib/resend.ts";
if (!fs.existsSync(p)) {
  console.error("❌ Missing", p);
  process.exit(1);
}
let s = fs.readFileSync(p, "utf8");

// If class already has sendTicketReceipt, do nothing.
if (/sendTicketReceipt\s*\(/.test(s)) {
  console.log("✅ sendTicketReceipt already exists");
  process.exit(0);
}

// Add method inside class ResendMailer (best-effort).
// We add it right after sendReceipt(...) if exists, otherwise before last '}' of class.
if (/sendReceipt\s*\(/.test(s)) {
  s = s.replace(/(sendReceipt\s*\([\s\S]*?\}\s*)\n(\s*\})/m, (m, a, b) => {
    const add = `
  // Compatibility alias (older code)
  async sendTicketReceipt(payload: any) {
    // prefer sendReceipt if present
    return this.sendReceipt(payload);
  }
`;
    return a + add + "\n" + b;
  });
} else {
  // fallback: inject before last closing brace in file (weak but works often)
  s = s.replace(/\n\}\s*$/m, `
  // Compatibility alias (older code)
  async sendTicketReceipt(payload: any) {
    // If your implementation uses another method name, map it here.
    // @ts-ignore
    if (typeof this.sendReceipt === "function") return this.sendReceipt(payload);
    throw new Error("ResendMailer: sendReceipt() not implemented");
  }
}
`);
}

fs.writeFileSync(p, s);
console.log("✅ Patched", p);
NODE

echo "==> [2] Patch adapters.ts: call mailer.sendReceipt OR sendTicketReceipt safely"
node - <<'NODE'
const fs = require("fs");
const p = "src/api/adapters.ts";
if (!fs.existsSync(p)) {
  console.error("❌ Missing", p);
  process.exit(1);
}
let s = fs.readFileSync(p, "utf8");

// Replace direct sendTicketReceipt calls with safe polymorphic call
// This fixes TS + runtime if method name differs.
s = s.replace(/args\.mailer\.sendTicketReceipt\s*\(/g, `(
  // @ts-ignore
  (args.mailer.sendTicketReceipt ? args.mailer.sendTicketReceipt.bind(args.mailer) : args.mailer.sendReceipt.bind(args.mailer))
)(`);

// Also if it calls mailer.sendReceipt already, keep it.
fs.writeFileSync(p, s);
console.log("✅ Patched", p);
NODE

echo "==> [3] Patch outbound.ts: remove missing Store type import '../store/types.js'"
node - <<'NODE'
const fs = require("fs");
const p = "src/api/outbound.ts";
if (!fs.existsSync(p)) {
  console.error("❌ Missing", p);
  process.exit(1);
}
let s = fs.readFileSync(p, "utf8");

// Remove the bad import if exists
s = s.replace(/^\s*import\s+type\s+\{\s*Store\s*\}\s+from\s+["']\.\.\/store\/types\.js["'];\s*\n/m, "");

// If it still references Store in types, replace with any minimal shape.
s = s.replace(/\bStore\b/g, "any");

fs.writeFileSync(p, s);
console.log("✅ Patched", p);
NODE

echo "==> [4] Patch server.ts: makeRoutes() should NOT receive tenants/shares (matches its declared type)"
node - <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
if (!fs.existsSync(p)) {
  console.error("❌ Missing", p);
  process.exit(1);
}
let s = fs.readFileSync(p, "utf8");

// Replace makeRoutes({ ..., tenants, shares }) -> makeRoutes({ ... })
s = s.replace(
  /makeRoutes\s*\(\s*\{\s*store\s*,\s*presetId\s*:\s*PRESET_ID\s*,\s*dedupeWindowSeconds\s*:\s*DEDUPE_WINDOW_SECONDS\s*,\s*tenants\s*,\s*shares\s*\}\s*\)/g,
  "makeRoutes({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS })"
);

// Also handle any variant ordering containing tenants/shares
s = s.replace(/makeRoutes\s*\(\s*\{([\s\S]*?)\}\s*\)/g, (m, inner) => {
  if (!inner.includes("tenants") && !inner.includes("shares")) return m;
  const cleaned = inner
    .split(",")
    .map(x => x.trim())
    .filter(x => x && !x.startsWith("tenants") && !x.startsWith("shares"));
  // Keep store/presetId/dedupeWindowSeconds if present; else fallback to canonical
  const joined = cleaned.join(", ");
  if (!/store/.test(joined) || !/presetId/.test(joined) || !/dedupeWindowSeconds/.test(joined)) {
    return "makeRoutes({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS })";
  }
  return `makeRoutes({ ${joined} })`;
});

fs.writeFileSync(p, s);
console.log("✅ Patched", p);
NODE

echo "==> [5] Typecheck"
pnpm -s lint:types

echo
echo "✅ OK. Now run:"
echo "  pnpm dev"
echo
echo "Then test:"
echo "  curl -i 'http://127.0.0.1:7090/ui/tickets?tenantId=tenant_demo&k=dev_key_123' | head -n 30"
echo "  open 'http://127.0.0.1:7090/ui/tickets?tenantId=tenant_demo&k=dev_key_123'"
