#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BAK=".bak/$(date -u +%Y%m%dT%H%M%SZ)_fix_admin_provision_button_debug_v1"
mkdir -p "$BAK"
echo "==> Backup dir: $BAK"

# backup file if exists
if [ -f "src/ui/admin_provision_route.ts" ]; then
  mkdir -p "$BAK/src/ui"
  cp "src/ui/admin_provision_route.ts" "$BAK/src/ui/admin_provision_route.ts.bak"
fi

cat > src/ui/admin_provision_route.ts <<'TS'
import type { Request, Response } from "express";

/**
 * Admin-only Founder Provision UI.
 * Goal: create a workspace + show the agency kit (links + webhook block) in one place.
 * This page MUST never fail silently: it prints HTTP status + error text.
 */
export function uiAdminProvision(req: Request, res: Response) {
  const adminKeyFromQuery = String(req.query.adminKey ?? "");
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>Founder Provision — One-Click Workspace</title>
<style>
  :root{
    --bg:#070A12;
    --card: rgba(17,24,39,.60);
    --line: rgba(255,255,255,.10);
    --muted:#9ca3af;
    --txt:#e5e7eb;
    --accent:#8b5cf6;
    --ok:#22c55e;
    --warn:#f59e0b;
    --bad:#ef4444;
    --shadow: 0 18px 60px rgba(0,0,0,.35);
    --r:16px;
  }
  *{box-sizing:border-box}
  body{
    margin:0;
    background: radial-gradient(1200px 700px at 20% 10%, rgba(96,165,250,.10), transparent 55%),
                radial-gradient(1100px 680px at 80% 20%, rgba(34,197,94,.10), transparent 52%),
                radial-gradient(900px 600px at 50% 90%, rgba(167,139,250,.10), transparent 60%),
                var(--bg);
    color:var(--txt);
    font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial;
  }
  .wrap{max-width:1100px;margin:42px auto;padding:0 18px}
  .card{
    border:1px solid var(--line);
    background: linear-gradient(180deg, rgba(255,255,255,.06), rgba(255,255,255,.03));
    box-shadow:var(--shadow);
    border-radius: var(--r);
    padding: 18px;
  }
  h1{margin:0 0 6px;font-size:22px}
  .sub{color:var(--muted);margin:0 0 16px}
  .row{display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin:10px 0 14px}
  .in{
    flex:1;min-width:220px;
    border:1px solid var(--line);
    background: rgba(0,0,0,.22);
    border-radius: 12px;
    padding: 10px 12px;
    color: var(--txt);
    outline: none;
  }
  .btn{
    border:1px solid var(--line);
    background: rgba(0,0,0,.20);
    color: var(--txt);
    padding: 10px 14px;
    border-radius: 12px;
    cursor: pointer;
    transition: transform .12s ease, background .12s ease;
    font-weight: 600;
  }
  .btn.primary{
    background: rgba(139,92,246,.22);
    border-color: rgba(139,92,246,.35);
  }
  .btn:hover{transform: translateY(-1px); background: rgba(255,255,255,.08)}
  .pill{
    margin-left:auto;
    display:inline-flex;align-items:center;gap:8px;
    padding:6px 10px;border:1px solid var(--line);
    background: rgba(0,0,0,.22);
    border-radius: 999px;
    color: var(--muted);
    font-size: 12px;
  }
  .dot{width:8px;height:8px;border-radius:999px;background: var(--ok)}
  .status{
    margin-top:12px;
    padding:10px 12px;
    border-radius: 12px;
    border:1px solid var(--line);
    background: rgba(0,0,0,.22);
    color: var(--muted);
    font-size: 13px;
    white-space: pre-wrap;
  }
  textarea{
    width:100%;
    min-height: 220px;
    border:1px solid var(--line);
    background: rgba(0,0,0,.22);
    border-radius: 12px;
    padding: 12px;
    color: var(--txt);
    outline: none;
    resize: vertical;
  }
  .hint{color:var(--muted);font-size:12px;margin-top:10px}
  .grid{display:grid;grid-template-columns:1fr;gap:12px;margin-top:12px}
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="row">
        <div>
          <h1>Founder Provision — One-Click Workspace</h1>
          <p class="sub">Create a client workspace and generate the agency kit (invite link + webhook + export links).</p>
        </div>
        <div class="pill"><span class="dot"></span> Admin-only</div>
      </div>

      <div class="row">
        <input id="adminKey" class="in" placeholder="admin key" value="${escapeHtml(adminKeyFromQuery)}" />
        <input id="workspaceName" class="in" placeholder="workspace name (e.g. ACME / salam)" value="salam" />
        <input id="agencyEmail" class="in" placeholder="agency email" value="test+agency@local.dev" />
        <button id="createBtn" type="button" class="btn primary">Create Workspace</button>
        <button id="clearBtn" type="button" class="btn">Clear</button>
      </div>

      <div id="status" class="status">Paste admin key, then click Create. (This page shows HTTP errors — no silent fails.)</div>

      <div class="grid">
        <textarea id="all" spellcheck="false" placeholder="Agency kit will appear here (copy/paste)."></textarea>
      </div>

      <div class="hint">
        Security note: Admin key is only used to create tenants. Tenant key is used by the agency to submit leads via webhook.
      </div>
    </div>
  </div>

<script>
  const $ = (id) => document.getElementById(id);

  function setStatus(msg, kind){
    const el = $("status");
    el.textContent = msg;
    el.style.color = (kind === "bad") ? "var(--bad)" : (kind === "ok") ? "var(--ok)" : "var(--muted)";
  }

  function buildBlock(json){
    const links = json.links || {};
    const webhook = json.webhook || {};
    const headers = webhook.headers || {};
    const bodyExample = webhook.bodyExample || {};

    return [
      "Decision Cover — Agency Kit",
      "",
      "Invite (Welcome):",
      (links.welcome || ""),
      "",
      "Pilot (recommended):",
      (links.pilot || ""),
      "",
      "Tickets:",
      (links.tickets || ""),
      "",
      "Decisions:",
      (links.decisions || ""),
      "",
      "Export CSV:",
      (links.csv || ""),
      "",
      "Evidence ZIP:",
      (links.zip || ""),
      "",
      "Webhook (Zapier/Form POST):",
      "URL: " + (webhook.url || ""),
      "Headers:",
      "  content-type: application/json",
      "  x-tenant-key: " + (headers["x-tenant-key"] || ""),
      "",
      "Body example:",
      JSON.stringify(bodyExample, null, 2),
      "",
      "Quick test (curl):",
      (json.curl || "")
    ].join("\\n");
  }

  async function createWorkspace(){
    const adminKey = $("adminKey").value.trim();
    const workspaceName = $("workspaceName").value.trim();
    const agencyEmail = $("agencyEmail").value.trim();

    if(!adminKey) return setStatus("Missing admin key.", "bad");
    if(!workspaceName) return setStatus("Missing workspace name.", "bad");
    if(!agencyEmail) return setStatus("Missing agency email.", "bad");

    setStatus("Creating…", "warn");
    $("all").value = "";

    const url = new URL("/api/admin/provision", window.location.origin).toString();

    try{
      const resp = await fetch(url, {
        method: "POST",
        headers: {"content-type":"application/json"},
        body: JSON.stringify({ adminKey, workspaceName, agencyEmail })
      });

      const text = await resp.text();
      let json = null;
      try { json = JSON.parse(text); } catch(e){}

      if(!resp.ok){
        setStatus("HTTP " + resp.status + " — " + (json?.error || text || "Request failed"), "bad");
        return;
      }
      if(!json){
        setStatus("HTTP 200 but response is not JSON. Raw:\\n" + text, "bad");
        return;
      }

      $("all").value = buildBlock(json);
      setStatus("OK ✅ Workspace created. Copy the Agency Kit and send ONLY the Pilot link + webhook block.", "ok");
    }catch(err){
      setStatus("Network/JS error: " + (err?.message || String(err)), "bad");
    }
  }

  $("createBtn").addEventListener("click", createWorkspace);
  $("clearBtn").addEventListener("click", () => {
    $("all").value = "";
    setStatus("Cleared.", "warn");
  });
</script>
</body>
</html>`;

  res.status(200).type("html").send(html);
}

function escapeHtml(s: string) {
  return String(s || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
TS

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ admin provision UI patched (button now shows HTTP errors + prints kit)."
echo "Backup: $BAK"
