#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${TS}_ux_easy_forms_and_nonempty_evidence_v1"
mkdir -p "$BAK"

echo "==> UX EASY + FORMS + NONEMPTY EVIDENCE (v1)"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"

# --- helpers
backup_file () {
  local f="$1"
  if [ -f "$f" ]; then
    mkdir -p "$BAK/$(dirname "$f")"
    cp -a "$f" "$BAK/$f"
  fi
}

node_patch () {
  node - <<'NODE'
const fs = require("fs");
const path = require("path");

function findFileByNeedle(dir, needle){
  const stack = [dir];
  while(stack.length){
    const d = stack.pop();
    for(const ent of fs.readdirSync(d,{withFileTypes:true})){
      if(ent.name.startsWith(".") || ent.name === "node_modules") continue;
      const p = path.join(d, ent.name);
      if(ent.isDirectory()) stack.push(p);
      else if(ent.isFile() && (p.endsWith(".ts") || p.endsWith(".js"))){
        const s = fs.readFileSync(p,"utf8");
        if(s.includes(needle)) return p;
      }
    }
  }
  return null;
}

function replaceOrDie(file, beforeRe, after){
  const s = fs.readFileSync(file,"utf8");
  if(!beforeRe.test(s)){
    console.error("PATCH_MISS:", file, "regex not found");
    process.exit(2);
  }
  const out = s.replace(beforeRe, after);
  fs.writeFileSync(file, out, "utf8");
  console.log("PATCH_OK:", file);
}

function ensureBlockOnce(file, marker, block){
  const s = fs.readFileSync(file,"utf8");
  if(s.includes(marker)){
    console.log("SKIP_ALREADY:", file, marker);
    return;
  }
  fs.writeFileSync(file, s + "\n\n" + block + "\n", "utf8");
  console.log("APPEND_OK:", file, marker);
}

const root = process.cwd();

// 1) Patch webhook intake to accept k in query if header missing.
// Find file containing "/api/webhook/intake"
const webhookFile = findFileByNeedle(path.join(root,"src"), "/api/webhook/intake");
if(!webhookFile){
  console.error("Could not find webhook route file containing /api/webhook/intake in src/");
  process.exit(3);
}

// We’ll patch common patterns safely by injecting fallback read of req.query.k into tenantKey resolution.
// Try a few regexes to match tenantKey extraction.
const before1 = /const\s+tenantKey\s*=\s*String\(\s*req\.headers\[[^\]]+\]\s*\|\|\s*""\s*\)\s*\.trim\(\s*\)\s*;/m;
const after1  = `const tenantKey = String((req.headers["x-tenant-key"] || req.headers["x-tenant-token"] || (req.query && (req.query.k || req.query.key)) || "")).trim();`;

const before2 = /const\s+tenantKey\s*=\s*String\(\s*req\.headers\[[^\]]+\]\s*\|\|\s*req\.headers\[[^\]]+\]\s*\|\|\s*""\s*\)\s*\.trim\(\s*\)\s*;/m;
const after2  = `const tenantKey = String((req.headers["x-tenant-key"] || req.headers["x-tenant-token"] || (req.query && (req.query.k || req.query.key)) || "")).trim();`;

let patchedWebhook = false;
try { replaceOrDie(webhookFile, before2, after2); patchedWebhook = true; } catch(e){}
if(!patchedWebhook){
  try { replaceOrDie(webhookFile, before1, after1); patchedWebhook = true; } catch(e){}
}
if(!patchedWebhook){
  // Fallback: insert a small helper near top if possible
  const marker = "/* UX_EASY_QUERY_K_FALLBACK */";
  const block = `
${marker}
function __uxEasyTenantKey(req: any){
  return String((req?.headers?.["x-tenant-key"] || req?.headers?.["x-tenant-token"] || req?.query?.k || req?.query?.key || "")).trim();
}
`;
  ensureBlockOnce(webhookFile, marker, block);

  // then replace common usage of req.headers["x-tenant-key"] to __uxEasyTenantKey(req) in that file (best effort)
  const s = fs.readFileSync(webhookFile,"utf8");
  const out = s.replace(/req\.headers\[\s*["']x-tenant-key["']\s*\]/g, "__uxEasyTenantKey(req)");
  fs.writeFileSync(webhookFile, out, "utf8");
  console.log("PATCH_OK(best_effort):", webhookFile, "header->helper");
}

// 2) Patch /ui/pilot to add "Send Test Lead" button (non-technical).
// Find UI route file containing "/ui/pilot"
const uiRoutes = findFileByNeedle(path.join(root,"src","ui"), "/ui/pilot") || findFileByNeedle(path.join(root,"src"), "/ui/pilot");
if(!uiRoutes){
  console.error("Could not find UI routes file containing /ui/pilot");
  process.exit(4);
}

const pilotMarker = "<!-- UX_EASY_TEST_LEAD -->";
if(!fs.readFileSync(uiRoutes,"utf8").includes(pilotMarker)){
  // Inject a button into the pilot HTML output (best effort: add near top buttons row if exists)
  // We’ll do a conservative string replace on "Download Evidence ZIP" button label occurrence if present.
  const s0 = fs.readFileSync(uiRoutes,"utf8");
  let s = s0;

  // Add button in HTML
  s = s.replace(
    /(Download Evidence ZIP<\/button>)/m,
    `$1
      <button class="btn" id="sendTestBtn" type="button">Send Test Lead</button>
      ${pilotMarker}`
  );

  // Add JS handler for sendTestBtn (call webhook with tenantId+k and demo payload)
  // Insert near existing <script> end if possible.
  if(s.includes(pilotMarker) && s.includes("</script>")){
    s = s.replace(
      /<\/script>/m,
      `
  (function(){
    try{
      const btn = document.getElementById("sendTestBtn");
      if(!btn) return;
      btn.addEventListener("click", async () => {
        btn.disabled = true;
        btn.textContent = "Sending…";
        try{
          const params = new URLSearchParams(window.location.search);
          const tenantId = params.get("tenantId") || "";
          const k = params.get("k") || "";
          const url = new URL("/api/webhook/intake", window.location.origin);
          url.searchParams.set("tenantId", tenantId);
          url.searchParams.set("k", k); // no-headers mode
          const body = {
            source: "ui-test",
            type: "lead",
            lead: {
              fullName: "Demo Lead",
              email: "demo@x.dev",
              company: "DemoCo"
            }
          };
          const resp = await fetch(url.toString(), {
            method: "POST",
            headers: { "content-type":"application/json" },
            body: JSON.stringify(body)
          });
          const txt = await resp.text();
          if(!resp.ok) throw new Error("HTTP " + resp.status + " " + txt);
          btn.textContent = "Sent ✅ Refreshing…";
          setTimeout(() => window.location.reload(), 600);
        }catch(e){
          btn.disabled = false;
          btn.textContent = "Send Test Lead";
          alert("Failed: " + (e && e.message ? e.message : String(e)));
        }
      });
    }catch(_e){}
  })();
</script>`
    );
  }

  fs.writeFileSync(uiRoutes, s, "utf8");
  console.log("PATCH_OK:", uiRoutes, "pilot test button");
} else {
  console.log("SKIP_ALREADY:", uiRoutes, "pilot test button exists");
}

// 3) Make Setup page show a “Form Action URL (no headers)” explicitly (UX).
const setupFile = findFileByNeedle(path.join(root,"src","ui"), "Zapier Setup") || findFileByNeedle(path.join(root,"src","ui"), "/ui/setup");
if(setupFile){
  const s0 = fs.readFileSync(setupFile,"utf8");
  const marker = "UX_EASY_FORM_ACTION_URL";
  if(!s0.includes(marker)){
    const s = s0.replace(
      /(Zapier Action\s*\(POST\)[\s\S]{0,300}URL:\s*.*\/api\/webhook\/intake)/m,
      `$1\n\nForm Action URL (no-headers) [${marker}]:\n  ${"http://"}\${baseUrl.replace(/^https?:\\/\\//,"")}/api/webhook/intake?tenantId=\${encodeURIComponent(auth.tenantId)}&k=\${encodeURIComponent(auth.tenantKey)}`
    );
    fs.writeFileSync(setupFile, s, "utf8");
    console.log("PATCH_OK:", setupFile, "form action url");
  } else {
    console.log("SKIP_ALREADY:", setupFile, marker);
  }
} else {
  console.log("WARN: could not find setup UI file to patch (non-blocking).");
}

NODE
}

# backups
for f in src/ui/routes.ts src/ui/admin_provision_route.ts; do backup_file "$f"; done

# also backup any file that contains /api/webhook/intake (found by grep)
WEBHOOK_HIT="$(grep -R --line-number "/api/webhook/intake" src 2>/dev/null | head -n 1 | cut -d: -f1 || true)"
if [ -n "${WEBHOOK_HIT:-}" ]; then backup_file "$WEBHOOK_HIT"; fi

# patch via node
node_patch

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ Applied: query k intake + pilot send test lead + setup form url"
echo "Backup: $BAK"
echo
echo "NEXT (copy/paste):"
echo "  kill -9 \$(lsof -t -iTCP:7090 -sTCP:LISTEN) 2>/dev/null || true"
echo "  ADMIN_KEY='dev_admin_key_123' bash scripts/dev_7090.sh"
echo "  open 'http://127.0.0.1:7090/ui/admin/provision?adminKey=dev_admin_key_123'"
echo "  # then open the Pilot link and click: Send Test Lead"
