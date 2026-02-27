#!/usr/bin/env bash
set -euo pipefail

echo "==> UX EASY v2 (no-headers webhook + send test lead + nonempty evidence)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
BAK=".bak/${stamp}_ux_easy_v2"
mkdir -p "$BAK"

backup() {
  local f="$1"
  [ -f "$f" ] || return 0
  mkdir -p "$BAK/$(dirname "$f")"
  cp -a "$f" "$BAK/$f"
}

echo "==> backup key files"
backup "src/ui/routes.ts"
# any file containing the webhook route:
WEBHOOK_FILE="$(grep -R --line-number "/api/webhook/intake" src 2>/dev/null | head -n 1 | cut -d: -f1 || true)"
if [ -n "${WEBHOOK_FILE:-}" ]; then
  backup "$WEBHOOK_FILE"
fi

node <<'NODE'
const fs = require("fs");
const path = require("path");

function findFirstFileWithNeedle(dir, needle){
  const st = fs.statSync(dir);
  if(st.isFile()){
    const s = fs.readFileSync(dir,"utf8");
    return s.includes(needle) ? dir : null;
  }
  const items = fs.readdirSync(dir);
  for(const it of items){
    if(it.startsWith(".") || it === "node_modules") continue;
    const p = path.join(dir,it);
    const s = fs.statSync(p);
    if(s.isDirectory()){
      const hit = findFirstFileWithNeedle(p, needle);
      if(hit) return hit;
    } else if(s.isFile()){
      const c = fs.readFileSync(p,"utf8");
      if(c.includes(needle)) return p;
    }
  }
  return null;
}

function writeIfChanged(file, next){
  const prev = fs.readFileSync(file,"utf8");
  if(prev === next){
    console.log("SKIP (no change):", file);
    return;
  }
  fs.writeFileSync(file, next, "utf8");
  console.log("PATCH_OK:", file);
}

const root = process.cwd();

// 1) Patch webhook intake: accept k in query when header missing
const webhookFile =
  findFirstFileWithNeedle(path.join(root,"src"), "/api/webhook/intake");

if(!webhookFile){
  console.error("ERROR: could not find webhook file containing /api/webhook/intake");
  process.exit(2);
}

let w = fs.readFileSync(webhookFile,"utf8");
const marker1 = "/* UX_EASY_NO_HEADERS_WEBHOOK */";
if(!w.includes(marker1)){
  // Try to patch a common pattern: tenantKey derived only from headers.
  // We'll do best-effort: insert helper + replace obvious reads.
  const helper = `
${marker1}
function __tenantKeyFromReq(req){
  // Prefer headers (Zapier/Make/n8n). Fallback to query k (Google Forms/Webflow/Typeform).
  return String(
    (req?.headers?.["x-tenant-key"] ||
     req?.headers?.["x-tenant-token"] ||
     req?.query?.k ||
     req?.query?.key ||
     "")
  ).trim();
}
`;
  w = helper + "\n" + w;

  // Replace common header-only usages inside this file (best effort)
  w = w.replace(/req\.headers\[\s*["']x-tenant-key["']\s*\]/g, "__tenantKeyFromReq(req)");
  w = w.replace(/req\.headers\[\s*["']x-tenant-token["']\s*\]/g, "__tenantKeyFromReq(req)");

  // If there is a line: const tenantKey = String(...).trim(); we force it:
  w = w.replace(
    /const\s+tenantKey\s*=\s*String\([\s\S]{0,180}?\)\s*\.trim\(\s*\)\s*;/m,
    'const tenantKey = __tenantKeyFromReq(req);'
  );

  writeIfChanged(webhookFile, w);
} else {
  console.log("SKIP_ALREADY:", webhookFile, marker1);
}

// 2) Patch UI: Add "Send Test Lead" button in /ui/pilot
const uiRoutesFile =
  fs.existsSync(path.join(root,"src","ui","routes.ts"))
    ? path.join(root,"src","ui","routes.ts")
    : findFirstFileWithNeedle(path.join(root,"src"), "/ui/pilot");

if(!uiRoutesFile){
  console.error("ERROR: could not find UI routes containing /ui/pilot");
  process.exit(3);
}

let u = fs.readFileSync(uiRoutesFile,"utf8");
const marker2 = "<!-- UX_EASY_SEND_TEST_LEAD -->";
if(!u.includes(marker2)){
  // Insert button near existing buttons area by matching "Download Evidence ZIP"
  u = u.replace(
    /(Download Evidence ZIP<\/button>)/m,
    `$1
      <button class="btn" id="sendTestLeadBtn" type="button">Send Test Lead</button>
      ${marker2}`
  );

  // Inject JS handler before first </script> in the pilot page HTML
  u = u.replace(
    /<\/script>/m,
    `
  (function(){
    try{
      const btn = document.getElementById("sendTestLeadBtn");
      if(!btn) return;
      btn.addEventListener("click", async () => {
        btn.disabled = true;
        const old = btn.textContent;
        btn.textContent = "Sending…";
        try{
          const p = new URLSearchParams(window.location.search);
          const tenantId = p.get("tenantId") || "";
          const k = p.get("k") || "";
          const url = new URL("/api/webhook/intake", window.location.origin);
          url.searchParams.set("tenantId", tenantId);
          url.searchParams.set("k", k); // no-headers mode
          const body = {
            source: "ui-test",
            type: "lead",
            lead: { fullName: "Demo Lead", email: "demo@x.dev", company: "DemoCo" }
          };
          const resp = await fetch(url.toString(), {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(body)
          });
          const txt = await resp.text();
          if(!resp.ok) throw new Error("HTTP " + resp.status + " " + txt);
          btn.textContent = "Sent ✅ Refreshing…";
          setTimeout(() => window.location.href = window.location.href, 700);
        } catch(e){
          btn.disabled = false;
          btn.textContent = old || "Send Test Lead";
          alert("Send failed: " + (e?.message || String(e)));
        }
      });
    }catch(_e){}
  })();
</script>`
  );

  writeIfChanged(uiRoutesFile, u);
} else {
  console.log("SKIP_ALREADY:", uiRoutesFile, marker2);
}

// 3) UX: Ensure Setup shows Form Action URL (No Headers)
let u2 = fs.readFileSync(uiRoutesFile,"utf8");
const marker3 = "/* UX_EASY_FORM_ACTION_URL */";
if(!u2.includes(marker3) && u2.includes("/ui/setup")){
  // Append a small hint block in setup HTML builder by simple injection near "Zapier Action (POST):"
  u2 = u2.replace(
    /(Zapier Action\s*\(POST\)[\s\S]{0,600}?URL:\s*[^\n<]+)/m,
    `$1
\n\nForm Action URL (No Headers) — paste into Webflow/Typeform/Google Forms webhook field:
${marker3}
  \${baseUrl}/api/webhook/intake?tenantId=\${encodeURIComponent(auth.tenantId)}&k=\${encodeURIComponent(auth.tenantKey)}
`
  );
  writeIfChanged(uiRoutesFile, u2);
} else {
  console.log("SKIP (setup injection):", uiRoutesFile);
}

// 4) Nonempty Evidence ZIP: create evidence snapshot per ticket if evidence folder empty
let u3 = fs.readFileSync(uiRoutesFile,"utf8");
const marker4 = "/* UX_EASY_EVIDENCE_SNAPSHOT */";
if(!u3.includes(marker4) && u3.includes("/ui/evidence.zip")){
  // Best-effort: inject just before archiving folder (look for "evidence" dir creation or zip logic)
  // We'll add a tiny helper that writes JSON snapshots inside evidence/ if none exist.
  const inject = `
${marker4}
function __ensureEvidenceNotEmpty(workDir: string, tickets: any[]){
  try{
    const evDir = require("path").join(workDir, "evidence");
    require("fs").mkdirSync(evDir, { recursive: true });
    const files = require("fs").readdirSync(evDir).filter((x: string) => !x.startsWith("."));
    if(files.length > 0) return;
    // write at least one snapshot per ticket (or a placeholder)
    if(!tickets || tickets.length === 0){
      require("fs").writeFileSync(require("path").join(evDir, "README.txt"), "No tickets yet. Send a test lead to generate proof.", "utf8");
      return;
    }
    for(const t of tickets.slice(0, 50)){
      const id = String(t.id || t.ticketId || t.createdAtUtc || Date.now());
      require("fs").writeFileSync(require("path").join(evDir, "ticket_" + id + ".json"), JSON.stringify(t, null, 2), "utf8");
    }
  }catch(_e){}
}
`;
  // Add helper near top of file (after imports) safely
  if(!u3.includes(marker4)){
    u3 = inject + "\n" + u3;
  }

  // Call helper in evidence.zip route: find a place after "tickets" array is available.
  // We'll look for "ticketsToCsv(" usage and hook after it.
  u3 = u3.replace(
    /(const\s+csv\s*=\s*ticketsToCsv\([^)]+\);\s*)/m,
    `$1\n    __ensureEvidenceNotEmpty(workDir, rows as any);\n`
  );

  writeIfChanged(uiRoutesFile, u3);
} else {
  console.log("SKIP (evidence snapshot injection):", uiRoutesFile);
}

console.log("OK: UX EASY v2 patches applied");
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ UX EASY v2 applied"
echo "Backup: $BAK"
echo
echo "NEXT:"
echo "  kill -9 \$(lsof -t -iTCP:7090 -sTCP:LISTEN) 2>/dev/null || true"
echo "  ADMIN_KEY='dev_admin_key_123' bash scripts/dev_7090.sh"
echo "  open 'http://127.0.0.1:7090/ui/admin/provision?adminKey=dev_admin_key_123'"
echo "  # Create Workspace -> open Pilot -> click Send Test Lead -> open Tickets -> Download Evidence ZIP"
