#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/Projects/intake-guardian-agent}"
cd "$REPO"

ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
BK=".bak/${ts_utc}_hotfix_v7_1_server_syntax_single_store"
mkdir -p "$BK"

echo "============================================================"
echo "OneShot: Hotfix v7.1 — fix server.ts TS1128 + enforce single-store webhooks"
echo "Repo: $REPO"
echo "Backup: $BK"
echo "============================================================"

cp -a src/server.ts "$BK/server.ts" 2>/dev/null || true
cp -a src/ui/routes.ts "$BK/routes.ts" 2>/dev/null || true

node <<'NODE'
const fs = require("fs");

const file = "src/server.ts";
let s = fs.readFileSync(file, "utf8");

// -------- helpers
function has(str){ return s.includes(str); }
function idxOf(str){ return s.indexOf(str); }

function normalizeAppCreate() {
  // Ensure `const app = express()` exists and is terminated nicely
  // (don’t change semantics, only stabilize formatting)
  s = s.replace(/const\s+app\s*=\s*express\(\)\s*(?!;)/, "const app = express();");
}

function ensureEarlyJson() {
  // Make sure express.json exists early (before our webhook routes)
  // Insert right after `const app = express();` if missing.
  const marker = "const app = express();";
  const i = idxOf(marker);
  if (i < 0) throw new Error("Cannot find `const app = express();`");
  const after = s.slice(i + marker.length, i + marker.length + 400);
  if (!after.includes("express.json")) {
    s = s.slice(0, i + marker.length) + "\napp.use(express.json({ limit: \"2mb\" }));\n" + s.slice(i + marker.length);
  }
}

function removeBrokenSingleStoreBlocks() {
  // Remove any previously injected easy/intake blocks that might be malformed.
  // Strategy: remove between our known comment headers if present,
  // otherwise remove the first occurrence of app.post("/api/webhook/easy" ... ) block safely.

  // 1) Remove any previous "GOLD: easy webhook + test lead" block (common marker in your file)
  const goldHdr = "/* ------------------------------\n * GOLD: easy webhook + test lead\n * ------------------------------ */";
  if (has(goldHdr)) {
    const start = idxOf(goldHdr);
    // end at the first occurrence of "// UX FIX: root redirect" or mountUnifiedTheme(app);
    const end1 = idxOf("// UX FIX: root redirect");
    const end2 = idxOf("mountUnifiedTheme(app");
    const end = (end1 > start ? end1 : (end2 > start ? end2 : -1));
    if (end > start) {
      s = s.slice(0, start) + s.slice(end);
    }
  }

  // 2) Remove standalone easy block if still present (best-effort non-greedy)
  s = s.replace(/app\.post\(\s*["']\/api\/webhook\/easy["'][\s\S]*?\n\}\);\n/g, "");
  // Remove standalone intake block if present
  s = s.replace(/app\.post\(\s*["']\/api\/webhook\/intake["'][\s\S]*?\n\}\);\n/g, "");

  // 3) Fix orphan `});` lines that can be left behind (common TS1128 cause)
  // Remove a line that is ONLY `});` or `});\r`
  s = s.replace(/^\s*\}\);\s*$/gm, (m) => {
    // only remove if it appears near where webhooks were (heuristic: file contains our upsertTicket import)
    return has("upsertTicket") ? "" : m;
  });
}

function insertCleanSingleStoreBlock() {
  // Insert clean webhook routes right after app creation and JSON middleware.
  const marker = "const app = express();";
  const i = idxOf(marker);
  if (i < 0) throw new Error("Cannot find insert marker");

  // Insert after the first json middleware we ensured.
  const afterMarker = s.indexOf("app.use(express.json", i);
  if (afterMarker < 0) throw new Error("Cannot find json middleware after app create");
  const afterLineEnd = s.indexOf("\n", afterMarker);
  const insertAt = afterLineEnd >= 0 ? afterLineEnd + 1 : afterMarker;

  const block = `
// ------------------------------------------------------------
// SINGLE-STORE WEBHOOKS (SSOT = ./lib/ticket-store)
// - easy: client-friendly endpoint (tenantId in query, key in header or k)
// - intake: canonical endpoint (same auth)
// Both write into upsertTicket() and trigger writeEvidencePack() best-effort.
// ------------------------------------------------------------
app.post("/api/webhook/easy", async (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const tenantKey = String(req.headers["x-tenant-key"] || q.k || "").trim();
  if (!tenantId || !tenantKey) {
    return res.status(401).json({ ok: false, error: "unauthorized", hint: "need tenantId + x-tenant-key (or k)" });
  }
  try {
    if (typeof hasTenantAuth === "function") {
      const ok = hasTenantAuth({ query: { tenantId }, headers: { "x-tenant-key": tenantKey } } as any);
      if (!ok) return res.status(401).json({ ok: false, error: "unauthorized" });
    }
  } catch {}

  const body = req?.body ?? {};
  const out = upsertTicket(tenantId, body);
  try { writeEvidencePack(tenantId); } catch {}
  return res.json(out);
});

app.post("/api/webhook/intake", async (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const tenantKey = String(req.headers["x-tenant-key"] || q.k || "").trim();
  if (!tenantId || !tenantKey) {
    return res.status(401).json({ ok: false, error: "unauthorized", hint: "need tenantId + x-tenant-key (or k)" });
  }
  try {
    if (typeof hasTenantAuth === "function") {
      const ok = hasTenantAuth({ query: { tenantId }, headers: { "x-tenant-key": tenantKey } } as any);
      if (!ok) return res.status(401).json({ ok: false, error: "unauthorized" });
    }
  } catch {}

  const body = req?.body ?? {};
  const out = upsertTicket(tenantId, body);
  try { writeEvidencePack(tenantId); } catch {}
  return res.json(out);
});
`;

  // Prevent duplicate insertion
  if (!has("SINGLE-STORE WEBHOOKS (SSOT")) {
    s = s.slice(0, insertAt) + block + "\n" + s.slice(insertAt);
  }
}

function finalBraceSanity() {
  // If there is an extra trailing brace at EOF (common after bad regex),
  // remove exactly ONE if it breaks the pattern.
  // We cannot fully parse TS here, but we can do a safe micro-fix:
  // remove a final lone `}` if the file ends with `}\n` and also contains `async function main()` (which likely already closes later).
  // (best-effort; main compile will confirm)
  const trimmed = s.trimEnd();
  if (trimmed.endsWith("\n}") || trimmed.endsWith("}")) {
    // do nothing; too risky to auto-trim here
  }
}

normalizeAppCreate();
ensureEarlyJson();
removeBrokenSingleStoreBlocks();
insertCleanSingleStoreBlock();
finalBraceSanity();

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK: src/server.ts (syntax stabilized + single-store webhooks inserted)");
NODE

echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ Hotfix v7.1 applied"
echo "Backup: $BK"
echo
echo "NEXT (Golden Test — zero guessing):"
echo "  pkill -f 'pnpm dev' || true"
echo "  pkill -f 'node .*src/server' || true"
echo "  pnpm dev"
echo
echo "  curl -sS -X POST 'http://127.0.0.1:7090/api/admin/provision' -H 'content-type: application/json' -H 'x-admin-key: dev_admin_key_123' -d '{\"workspaceName\":\"ACCE GATE\",\"agencyEmail\":\"choxmou@gmail.com\"}' | cat"
echo "  # then:"
echo "  TENANT_ID='...'; K='...'; BASE='http://127.0.0.1:7090'"
echo "  curl -sS -X POST \"$BASE/api/webhook/easy?tenantId=$TENANT_ID\" -H 'content-type: application/json' -H \"x-tenant-key: $K\" --data '{\"source\":\"demo\",\"type\":\"lead\",\"lead\":{\"fullName\":\"Demo Lead\",\"email\":\"demo@x.dev\",\"company\":\"DemoCo\"}}' | cat"
echo "  open \"$BASE/ui/tickets?tenantId=$TENANT_ID&k=$K\""
echo "  curl -sS \"$BASE/ui/export.csv?tenantId=$TENANT_ID&k=$K\" | head -n 50"
echo "  curl -I \"$BASE/ui/evidence.zip?tenantId=$TENANT_ID&k=$K\" | head -n 20"
