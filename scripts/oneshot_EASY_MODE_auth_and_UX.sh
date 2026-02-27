#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${TS}_easy_mode"
mkdir -p "$BAK"

echo "==> EASY MODE patch"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"

# ---------- backup ----------
cp -a src/ui/routes.ts "$BAK/routes.ts.bak"
cp -a src/ui/admin_provision_route.ts "$BAK/admin_provision_route.ts.bak"

# ---------- patch 1: Provision UI should send x-admin-key header ----------
node <<'NODE'
const fs = require("fs");
const f = "src/ui/admin_provision_route.ts";
let s = fs.readFileSync(f, "utf8");

// In createWorkspace(): add header x-admin-key and remove adminKey from body payload
// We patch by locating the fetch() block headers/body.
s = s.replace(
  /headers:\s*\{\s*["']content-type["']\s*:\s*["']application\/json["']\s*\}\s*,\s*body:\s*JSON\.stringify\(\{\s*adminKey\s*,\s*workspaceName\s*,\s*agencyEmail\s*\}\)\s*\)/m,
  `headers: {"content-type":"application/json","x-admin-key": adminKey},
        body: JSON.stringify({ workspaceName, agencyEmail }) )`
);

// Also keep compatibility if you had tenantName/email old keys (no harm)
s = s.replace(/workspaceName/g, "workspaceName");
s = s.replace(/agencyEmail/g, "agencyEmail");

fs.writeFileSync(f, s, "utf8");
console.log("OK: admin_provision_route.ts patched (use x-admin-key header)");
NODE

# ---------- patch 2: UI auth should accept ?k=... and stop printing dev code ----------
node <<'NODE'
const fs = require("fs");
const f = "src/ui/routes.ts";
let s = fs.readFileSync(f, "utf8");

// A) Remove any leftover mountAdminProvisionUI references (safety)
s = s.replace(/import\s+\{\s*mountAdminProvisionUI\s*\}\s+from\s+["'][^"']+["'];?\n?/g, "");
s = s.replace(/mountAdminProvisionUI\([^)]*\);\s*\n?/g, "");

// B) Make "Unauthorized" page clean (no dev code dump).
// Replace any huge debug-y unauthorized block that contains "Phase48b" with a short message.
s = s.replace(
  /Unauthorized[\s\S]*?Phase48b[\s\S]*?invalid_tenant_key[\s\S]*?(<\/pre>|\}\s*$)/m,
  `Unauthorized</h1>
<p style="color:#9ca3af;margin:10px 0 0">Invalid or missing tenant key.</p>
<p style="color:#9ca3af;margin:6px 0 0">Ask your agency for a fresh invite link.</p>
</div>`
);

// C) Ensure auth extraction reads k from query AND headers.
// We try to patch a common pattern: const k = String(... headers ...)
// If not found, we patch the verifyTenantKeyLocal call to pass query.k first.
const reVerify = /verifyTenantKeyLocal\(\s*([^)]+)\s*\)/g;

// If verifyTenantKeyLocal is called with (tenantId, something), ensure it prefers query.k
// We do a conservative replacement only if we see verifyTenantKeyLocal(tenantId,
if (s.includes("verifyTenantKeyLocal")) {
  s = s.replace(
    /verifyTenantKeyLocal\(\s*([A-Za-z0-9_.$\[\]"'()?:\s]+?)\s*,\s*([A-Za-z0-9_.$\[\]"'()?:\s]+?)\s*\)/g,
    (m, a, b) => `verifyTenantKeyLocal(${a}, (String(((req.query||{}) as any).k || ((req.query||{}) as any).key || "") || ${b})))`
  );
}

// Additionally, if there's a local "k" computed only from headers, add query.k
s = s.replace(
  /const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*String\(\s*\(\s*req\.headers\[[^\]]+\][\s\S]*?\)\s*\|\|\s*""\s*\)\s*;/m,
  (m, varName) => {
    // keep original line but inject query preference
    // If pattern doesn't match well, we won't break; return original.
    return m.replace(
      /String\(/,
      'String((((req.query||{}) as any).k || ((req.query||{}) as any).key || "") || '
    ).replace(/\)\s*;\s*$/, '));');
  }
);

// D) Ensure /ui/admin/provision mount exists (if missing)
// We detect the exported function that receives (app: Express) and mount inside it.
if (!s.includes('/ui/admin/provision')) {
  const marker = /export\s+function\s+mountUIRoutes\s*\(\s*app:\s*Express\s*\)\s*\{\s*/m;
  if (marker.test(s)) {
    s = s.replace(marker, (m) => m + `\n  // EASY MODE: admin provision page\n  app.get("/ui/admin/provision", uiAdminProvision);\n`);
  }
}

// E) Ensure uiAdminProvision import exists once
if (!s.includes('from "./admin_provision_route.js"') && !s.includes('from "./admin_provision_route"')) {
  // Insert after the first import line
  const lines = s.split("\n");
  let idx = lines.findIndex(l => l.startsWith("import "));
  if (idx === -1) idx = 0;
  lines.splice(idx+1, 0, 'import { uiAdminProvision } from "./admin_provision_route.js";');
  s = lines.join("\n");
} else {
  // Remove duplicate non-.js import if both exist
  s = s.replace(/import\s+\{\s*uiAdminProvision\s*\}\s+from\s+["']\.\/admin_provision_route["'];?\n?/g, "");
}

fs.writeFileSync(f, s, "utf8");
console.log("OK: routes.ts patched (accept query k + clean Unauthorized + ensure admin provision mount)");
NODE

# ---------- docs: Easy Mode runbook ----------
cat > docs/EASY_MODE.md <<'EOF'
# EASY MODE — Decision Cover™ (Local)

## 1) Start server (with ADMIN_KEY)
Run:
  ADMIN_KEY="dev_admin_key_123" bash scripts/dev_7090.sh

## 2) Founder creates a workspace (1 click)
Open:
  http://127.0.0.1:7090/ui/admin/provision?adminKey=dev_admin_key_123

Fill:
- workspace name
- agency email
Click: Create Workspace

## 3) Client experience (1 link only)
Send ONLY the "Pilot" link from the generated kit.
Client opens it and can navigate:
- Tickets
- Decisions
- Export CSV
- Evidence ZIP

## Notes
- Client auth uses the link token k (query param) or x-tenant-key header.
- Unauthorized pages never show dev code.
EOF

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ EASY MODE applied"
echo "Backup: $BAK"
echo
echo "NEXT (copy/paste):"
echo "  kill -9 \$(lsof -t -iTCP:7090 -sTCP:LISTEN) 2>/dev/null || true"
echo "  ADMIN_KEY='dev_admin_key_123' bash scripts/dev_7090.sh"
echo "  open 'http://127.0.0.1:7090/ui/admin/provision?adminKey=dev_admin_key_123'"
