#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/Projects/intake-guardian-agent}"
cd "$REPO"

ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
BK=".bak/${ts_utc}_hotfix_v7_2_rollback_server_clean_easy"
mkdir -p "$BK"

echo "============================================================"
echo "OneShot: Hotfix v7.2 — rollback server.ts to last known-good + clean easy/ui routes"
echo "Repo: $REPO"
echo "Backup: $BK"
echo "============================================================"

cp -a src/server.ts "$BK/server.ts.current" 2>/dev/null || true
cp -a src/ui/routes.ts "$BK/routes.ts.current" 2>/dev/null || true

echo "==> [1] Find latest backup containing server.ts"
restore=""
for d in $(ls -1d .bak/* 2>/dev/null | sort -r); do
  if [ -f "$d/server.ts" ]; then
    restore="$d/server.ts"
    break
  fi
done

if [ -z "${restore}" ]; then
  echo "ERROR: no backup .bak/*/server.ts found. Cannot auto-rollback."
  echo "Tip: list backups: ls -1d .bak/* | tail -n 20"
  exit 1
fi

echo "==> [2] Rollback src/server.ts from: $restore"
cp -a "$restore" src/server.ts
cp -a "$restore" "$BK/server.ts.rolled_back"

echo "==> [3] Patch server.ts (safe clean insert): early JSON middleware + /api/webhook/easy + /api/ui/send-test-lead"
node <<'NODE'
const fs = require("fs");

const file = "src/server.ts";
let s = fs.readFileSync(file, "utf8");

// Helpers
const has = (x) => s.includes(x);
const idx = (x) => s.indexOf(x);

// 1) Ensure `const app = express();` exists (most versions have it)
if (!has("const app = express")) {
  throw new Error("Cannot find `const app = express` in server.ts after rollback.");
}

// 2) Ensure JSON middleware EARLY (right after app creation), remove later duplicates
// Insert after the first occurrence of `const app = express();` line end.
s = s.replace(/const\s+app\s*=\s*express\(\)\s*;?/g, "const app = express();");

const appLine = "const app = express();";
let p = idx(appLine);
if (p < 0) throw new Error("Cannot locate normalized app line");

let lineEnd = s.indexOf("\n", p);
if (lineEnd < 0) lineEnd = p + appLine.length;

const earlyMw =
`app.use(express.urlencoded({ extended: true }));
app.use(express.json({ limit: "2mb" }));\n`;

const window = s.slice(lineEnd, lineEnd + 500);
if (!window.includes("express.json") && !window.includes("express.urlencoded")) {
  s = s.slice(0, lineEnd + 1) + earlyMw + s.slice(lineEnd + 1);
}

// Remove later duplicates (keep first)
let seenJson = false;
s = s.replace(/^\s*app\.use\(express\.json\([^\)]*\)\);\s*$/gm, (m) => {
  if (!seenJson) { seenJson = true; return m; }
  return "";
});
let seenUrl = false;
s = s.replace(/^\s*app\.use\(express\.urlencoded\([^\)]*\)\);\s*$/gm, (m) => {
  if (!seenUrl) { seenUrl = true; return m; }
  return "";
});

// 3) Insert clean EASY + SEND-TEST-LEAD routes once (near app creation, after early middleware)
if (!has('app.post("/api/webhook/easy"')) {
  // Insert right after early middleware block (or after appLine if MW already there)
  let insertAt = idx(earlyMw.trim());
  if (insertAt >= 0) {
    insertAt = insertAt + earlyMw.length;
  } else {
    // fallback: insert after appLine
    insertAt = s.indexOf("\n", idx(appLine));
    insertAt = insertAt >= 0 ? insertAt + 1 : 0;
  }

  const block = `
// ------------------------------------------------------------
// GOLD: client-friendly endpoints (no guessing UX)
// - /api/webhook/easy?tenantId=...&k=...  (k optional if header present)
// - /api/ui/send-test-lead?tenantId=...&k=...
// Both forward to the canonical intake webhook (existing /api/webhook/intake).
// IMPORTANT: JSON middleware is mounted BEFORE these routes.
// ------------------------------------------------------------
app.post("/api/webhook/easy", async (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const tenantKey = String(req.headers["x-tenant-key"] || q.k || "").trim();
  if (!tenantId || !tenantKey) {
    return res.status(401).json({ ok: false, error: "unauthorized", hint: "need tenantId + x-tenant-key (or k)" });
  }

  const proto = String(req.headers["x-forwarded-proto"] || ((req.socket && (req.socket as any).encrypted) ? "https" : "http"));
  const host  = String(req.headers["x-forwarded-host"] || req.headers.host || "127.0.0.1");
  const base  = `${proto}://${host}`;

  const url = `${base}/api/webhook/intake?tenantId=${encodeURIComponent(tenantId)}`;

  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-tenant-key": tenantKey },
    body: JSON.stringify(req.body ?? {}),
  });

  const text = await r.text();
  res.status(r.status);
  res.setHeader("content-type", r.headers.get("content-type") || "application/json");
  return res.send(text);
});

app.post("/api/ui/send-test-lead", async (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const k = String(q.k || req.headers["x-tenant-key"] || "").trim();
  if (!tenantId || !k) {
    return res.status(401).json({ ok: false, error: "unauthorized", hint: "need tenantId + k" });
  }

  const payload = {
    source: "ui",
    type: "lead",
    lead: { fullName: "UI Test Lead", email: "ui-test@local.dev", company: "DecisionCover" },
  };

  const proto = String(req.headers["x-forwarded-proto"] || ((req.socket && (req.socket as any).encrypted) ? "https" : "http"));
  const host  = String(req.headers["x-forwarded-host"] || req.headers.host || "127.0.0.1");
  const base  = `${proto}://${host}`;

  const url = `${base}/api/webhook/easy?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;

  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-tenant-key": k },
    body: JSON.stringify(payload),
  });

  const text = await r.text();
  res.status(r.status);
  res.setHeader("content-type", r.headers.get("content-type") || "application/json");
  return res.send(text);
});
`;
  s = s.slice(0, insertAt) + block + "\n" + s.slice(insertAt);
}

// 4) Hard guard: do NOT allow duplicated `main().catch` lines (rare but happens)
const lines = s.split(/\r?\n/);
let catchCount = 0;
for (let i=0;i<lines.length;i++){
  if (lines[i].includes("main().catch(")) catchCount++;
}
if (catchCount > 1) {
  // keep first occurrence, drop later ones
  let kept = false;
  const out = [];
  for (const ln of lines) {
    if (ln.includes("main().catch(")) {
      if (!kept) { out.push(ln); kept = true; }
      else continue;
    } else out.push(ln);
  }
  s = out.join("\n");
}

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK: server.ts (rollback-safe insert + early json + easy/send-test-lead)");
NODE

echo "==> [4] Ensure UI routes read from ticket-store (already in your latest hotfix, keep as-is)"
# no-op (we don't touch routes.ts here)

echo "==> [5] typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ Hotfix v7.2 applied"
echo "Backup: $BK"
echo
echo "NEXT (Golden Test — no guessing):"
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
