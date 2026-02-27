#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${TS}_easy_mode_fix"
mkdir -p "$BAK"

echo "==> EASY MODE FIX (restore + safe patch)"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"

# 1) Find latest easy_mode backup created by the broken oneshot
LAST_EASY="$(ls -dt .bak/*_easy_mode 2>/dev/null | head -n1 || true)"
if [[ -z "${LAST_EASY}" ]]; then
  echo "FAIL: No previous *_easy_mode backup found under .bak/"
  echo "Hint: list backups: ls -la .bak | tail"
  exit 1
fi

echo "==> Restoring from: $LAST_EASY"

# Backup current (broken) files
cp -a src/ui/routes.ts "$BAK/routes.ts.broken" || true
cp -a src/ui/admin_provision_route.ts "$BAK/admin_provision_route.ts.broken" || true

# Restore known-good copies from that backup
cp -a "$LAST_EASY/routes.ts.bak" src/ui/routes.ts
cp -a "$LAST_EASY/admin_provision_route.ts.bak" src/ui/admin_provision_route.ts

echo "OK: restored routes.ts + admin_provision_route.ts from backup"

# 2) Safe patch admin provision UI to use x-admin-key header (no TS parsing risk)
node <<'NODE'
const fs = require("fs");
const f = "src/ui/admin_provision_route.ts";
let s = fs.readFileSync(f, "utf8");

// Make provision UI send admin key via header (x-admin-key) and remove it from JSON body.
// We do a conservative patch: if the old body includes adminKey, replace that exact JSON.stringify payload.
s = s.replace(
  /headers:\s*\{\s*["']content-type["']\s*:\s*["']application\/json["']\s*\}\s*,\s*body:\s*JSON\.stringify\(\{\s*adminKey\s*,\s*workspaceName\s*,\s*agencyEmail\s*\}\)\s*\)/m,
  `headers: {"content-type":"application/json","x-admin-key": adminKey},
        body: JSON.stringify({ workspaceName, agencyEmail }) )`
);

// If it uses tenantName/email older payload, keep compatibility by not forcing names.
// (No-op if not present)
fs.writeFileSync(f, s, "utf8");
console.log("OK: admin_provision_route.ts patched (x-admin-key header)");
NODE

# 3) Safe patch routes.ts:
#    - Ensure /ui/admin/provision is mounted via uiAdminProvision
#    - Ensure ui tenant key accepts query ?k=... (lightweight)
#    - Ensure Unauthorized response is clean (no dev code leak)
node <<'NODE'
const fs = require("fs");
const f = "src/ui/routes.ts";
let s = fs.readFileSync(f, "utf8");

// A) Ensure uiAdminProvision import exists once (prefer .js)
if (!s.includes('uiAdminProvision')) {
  // Insert after first import block
  const lines = s.split("\n");
  let idx = lines.findIndex(l => l.startsWith("import "));
  if (idx < 0) idx = 0;
  lines.splice(idx+1, 0, 'import { uiAdminProvision } from "./admin_provision_route.js";');
  s = lines.join("\n");
} else {
  // Remove duplicate non-.js import if both exist
  s = s.replace(/import\s+\{\s*uiAdminProvision\s*\}\s+from\s+["']\.\/admin_provision_route["'];?\n?/g, "");
  // Ensure .js import exists
  if (!s.includes('from "./admin_provision_route.js"')) {
    const lines = s.split("\n");
    let idx = lines.findIndex(l => l.startsWith("import "));
    if (idx < 0) idx = 0;
    lines.splice(idx+1, 0, 'import { uiAdminProvision } from "./admin_provision_route.js";');
    s = lines.join("\n");
  }
}

// B) Ensure /ui/admin/provision mount exists (inside mountUIRoutes(app))
if (!s.includes('"/ui/admin/provision"')) {
  s = s.replace(
    /export\s+function\s+mountUIRoutes\s*\(\s*app:\s*Express\s*\)\s*\{\s*/m,
    (m) => m + `\n  // EASY MODE: Founder Provision\n  app.get("/ui/admin/provision", uiAdminProvision);\n`
  );
}

// C) Make tenant key read include query k/key by lightly patching the common tenantKey assignment.
// We patch ONLY if we find a line that sets tenantKey from headers (so we can prefix query).
// If pattern not found, we skip (no break).
const reTenantKeyLine = /const\s+tenantKey\s*=\s*String\(\s*(?:req\.headers\[[^\]]+\]|req\.header\([^)]+\)|\([^;]+headers[^;]+)\s*\|\|\s*""\s*\)\s*;/m;
if (reTenantKeyLine.test(s)) {
  s = s.replace(reTenantKeyLine, (m) => {
    return [
      'const __qk = String(((req.query || {}) as any).k || ((req.query || {}) as any).key || "");',
      m.replace(/String\(\s*/, 'String(__qk || ')
    ].join("\n");
  });
}

// D) Clean Unauthorized view: replace any Unauthorized block that contains "Phase48b" with a short message INSIDE htmlPage().
if (s.includes("Phase48b")) {
  // Replace the whole htmlPage(...) call that contains Phase48b with a clean one.
  s = s.replace(
    /htmlPage\(\s*["']Unauthorized["']\s*,[\s\S]*?Phase48b[\s\S]*?\)\s*\)/m,
    `htmlPage("Unauthorized", \`
      <div style="padding:24px">
        <h1 style="margin:0 0 10px 0">Unauthorized</h1>
        <p style="color:#9ca3af;margin:0">Invalid or missing tenant key.</p>
        <p style="color:#9ca3af;margin:6px 0 0">Ask your agency for a fresh invite link.</p>
      </div>
    \`)`
  );
}

// E) Safety: remove any leftover mountAdminProvisionUI import/calls
s = s.replace(/import\s+\{\s*mountAdminProvisionUI\s*\}\s+from\s+["'][^"']+["'];?\n?/g, "");
s = s.replace(/mountAdminProvisionUI\([^)]*\);\s*\n?/g, "");

fs.writeFileSync(f, s, "utf8");
console.log("OK: routes.ts patched safely (mount + query k + clean unauthorized)");
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ EASY MODE FIX applied"
echo "Backup (broken copies): $BAK"
echo
echo "NEXT:"
echo "  kill -9 \$(lsof -t -iTCP:7090 -sTCP:LISTEN) 2>/dev/null || true"
echo "  ADMIN_KEY='dev_admin_key_123' bash scripts/dev_7090.sh"
echo "  open 'http://127.0.0.1:7090/ui/admin/provision?adminKey=dev_admin_key_123'"
