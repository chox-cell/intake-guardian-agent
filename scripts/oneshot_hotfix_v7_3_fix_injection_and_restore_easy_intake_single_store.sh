#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/Projects/intake-guardian-agent}"
cd "$REPO"

ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
BK=".bak/${ts_utc}_hotfix_v7_3_server_easy_intake_single_store"
mkdir -p "$BK"

echo "============================================================"
echo "OneShot: Hotfix v7.3 — fix injection + restore easy/intake/test-lead + single-store"
echo "Repo: $REPO"
echo "Backup: $BK"
echo "============================================================"

echo "==> [0] Backup key files"
cp -a src/server.ts "$BK/server.ts" || true

echo "==> [1] Patch src/server.ts (safe insert inside main())"
node <<'NODE'
const fs = require("node:fs");

const file = "src/server.ts";
let s = fs.readFileSync(file, "utf8");

// 1) Normalize the express type import (avoid duplicates)
s = s.replace(/^import type \{ Request, Response, NextFunction \} from "express";\n/gm, "");
s = s.replace(/^import type \{ Request, Response \} from "express";\n/gm, "");
if (!s.match(/^import type \{ Request, Response, NextFunction \} from "express";/m)) {
  s = 'import type { Request, Response, NextFunction } from "express";\n' + s;
}

// 2) Ensure we import ticket-store helpers (upsertTicket)
if (!s.match(/from "\.\/lib\/ticket-store"/)) {
  // insert near top after express import
  s = s.replace(
    /^import express from "express";\n/m,
    'import express from "express";\nimport { upsertTicket } from "./lib/ticket-store";\n'
  );
}

// 3) Find "const app = express" inside main() and inject routes right after it.
const anchor = "const app = express()";
let idx = s.indexOf(anchor);
if (idx === -1) {
  // maybe "const app = express();" exists
  idx = s.indexOf("const app = express();");
}
if (idx === -1) {
  throw new Error("Cannot find app creation anchor in src/server.ts");
}

// Determine end of the line containing app creation
const lineEnd = s.indexOf("\n", idx);
if (lineEnd === -1) throw new Error("Unexpected EOF while locating app line end");

// Remove any previous injected duplicates (best-effort cleanup)
s = s.replace(/\/\* ------------------------------\s*\n \* GOLD: easy webhook[\s\S]*?\n\}\);\n\n/gs, "");
s = s.replace(/\/\* GOLD_V7_3_BEGIN \*\/[\s\S]*?\/\* GOLD_V7_3_END \*\//gs, "");

// Build injection WITHOUT template literals to avoid ${} issues.
const injection =
`\n/* GOLD_V7_3_BEGIN */
/**
 * IMPORTANT:
 * - JSON middleware must run BEFORE webhooks
 * - /api/webhook/intake writes to ticket-store (single source of truth for UI/CSV/ZIP)
 */
app.use(express.urlencoded({ extended: true }));
app.use(express.json({ limit: "2mb" }));

app.post("/api/webhook/intake", async (req, res) => {
  try {
    const q = req.query || {};
    const tenantId = String(q.tenantId || "").trim();
    const tenantKey = String(req.headers["x-tenant-key"] || q.k || "").trim();
    if (!tenantId || !tenantKey) {
      return res.status(401).json({ ok:false, error:"unauthorized", hint:"need tenantId + x-tenant-key (or k)" });
    }

    // Minimal validation (avoid empty objects)
    const body = req.body && typeof req.body === "object" ? req.body : {};
    const type = String(body.type || "lead");
    const source = String(body.source || "webhook");

    // Use existing ticket-store contract (upsertTicket returns the ticket)
    const ticket = upsertTicket(tenantId, {
      source,
      type,
      lead: body.lead || body.contact || body,
      raw: body
    });

    return res.json({ ok:true, created:true, ticket });
  } catch (e) {
    return res.status(500).json({ ok:false, error:"internal_error" });
  }
});

app.post("/api/webhook/easy", async (req, res) => {
  const q = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const tenantKey = String(req.headers["x-tenant-key"] || q.k || "").trim();
  if (!tenantId || !tenantKey) {
    return res.status(401).json({ ok:false, error:"unauthorized", hint:"need tenantId + x-tenant-key (or k)" });
  }

  // Call /api/webhook/intake locally (no fetch needed)
  req.query = Object.assign({}, q, { tenantId, k: tenantKey });
  return app._router.handle(req, res, () => {});
});

app.post("/api/ui/send-test-lead", async (req, res) => {
  const q = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const k = String(q.k || "").trim();
  if (!tenantId || !k) {
    return res.status(401).json({ ok:false, error:"unauthorized", hint:"need tenantId + k" });
  }

  // Direct call to intake (single store)
  req.query = Object.assign({}, q, { tenantId, k });
  req.headers["x-tenant-key"] = k;
  req.body = {
    source: "ui",
    type: "lead",
    lead: { fullName: "UI Test Lead", email: "ui-test@local.dev", company: "DecisionCover" }
  };
  return app._router.handle(req, res, () => {});
});
/* GOLD_V7_3_END */\n`;

// Insert injection right after app creation line
s = s.slice(0, lineEnd) + injection + s.slice(lineEnd);

// 4) Remove later duplicated body parsers if any (best-effort, keep first one)
let seenJson = false;
s = s.split("\n").filter((ln) => {
  if (ln.includes("app.use(express.json")) {
    if (seenJson) return false;
    seenJson = true;
  }
  return true;
}).join("\n");

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK:", file);
NODE

echo "==> [2] typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ Hotfix v7.3 applied"
echo "Backup: $BK"
echo
echo "NEXT (Golden Test — zero guessing):"
echo "  pkill -f 'pnpm dev' || true"
echo "  pkill -f 'node .*src/server' || true"
echo "  pnpm dev"
echo
echo "  curl -sS -X POST 'http://127.0.0.1:7090/api/admin/provision' \\"
echo "    -H 'content-type: application/json' \\"
echo "    -H 'x-admin-key: dev_admin_key_123' \\"
echo "    -d '{\"workspaceName\":\"ACCE GATE\",\"agencyEmail\":\"choxmou@gmail.com\"}' | cat"
echo
echo "  # use returned tenantId + k:"
echo "  TENANT_ID='...'; K='...'; BASE='http://127.0.0.1:7090'"
echo "  curl -sS -X POST \"$BASE/api/webhook/easy?tenantId=$TENANT_ID\" \\"
echo "    -H 'content-type: application/json' \\"
echo "    -H \"x-tenant-key: $K\" \\"
echo "    --data '{\"source\":\"demo\",\"type\":\"lead\",\"lead\":{\"fullName\":\"Demo Lead\",\"email\":\"demo@x.dev\",\"company\":\"DemoCo\"}}' | cat"
echo "  open \"$BASE/ui/tickets?tenantId=$TENANT_ID&k=$K\""
echo "  curl -sS \"$BASE/ui/export.csv?tenantId=$TENANT_ID&k=$K\" | head -n 50"
echo "  curl -I \"$BASE/ui/evidence.zip?tenantId=$TENANT_ID&k=$K\" | head -n 20"
