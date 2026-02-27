#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${TS}_ux_admin_provision_easy_v1"
mkdir -p "$BAK"

echo "==> One-shot UX: Make /ui/admin/provision agency-easy"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"

# locate file (we saw it in your logs)
F="src/ui/admin_provision_route.ts"
if [ ! -f "$F" ]; then
  echo "FAIL: $F not found"
  echo "Tip: list src/ui for provision file:"
  echo "  ls -la src/ui | grep -i provision"
  exit 1
fi

mkdir -p "$BAK/$(dirname "$F")"
cp -a "$F" "$BAK/$F"

cat > "$F" <<'EOF'
import type { Request, Response } from "express";

/**
 * Founder UI: /ui/admin/provision
 * UX goal: agency-easy
 * - Show only 2 inputs + 1 main button
 * - Primary output: Copy Pilot Link
 * - Advanced (optional): webhook block + other links
 *
 * Auth:
 * - adminKey comes from query param (?adminKey=...) and is sent as header x-admin-key
 */

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

export function uiAdminProvision(req: Request, res: Response) {
  const adminKey = String((req.query as any)?.adminKey || "").trim();

  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>Provision Workspace</title>
<style>
  :root{
    --bg:#0b0f14;
    --card:#0f1722;
    --muted:#9aa4b2;
    --text:#e6edf3;
    --ok:#22c55e;
    --bad:#ef4444;
    --warn:#f59e0b;
    --line:#223043;
    --btn:#2563eb;
    --btn2:#111827;
  }
  *{box-sizing:border-box}
  body{margin:0;background:linear-gradient(180deg,#05080d, #0b0f14);color:var(--text);font:14px/1.4 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto}
  .wrap{max-width:920px;margin:0 auto;padding:22px}
  .top{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:16px}
  .brand{font-weight:700;letter-spacing:.2px}
  .sub{color:var(--muted);font-size:12px}
  .grid{display:grid;grid-template-columns:1fr;gap:14px}
  .card{background:rgba(15,23,34,.9);border:1px solid var(--line);border-radius:14px;padding:16px}
  .row{display:grid;grid-template-columns:1fr 1fr;gap:10px}
  @media(max-width:760px){.row{grid-template-columns:1fr}}
  label{display:block;color:var(--muted);font-size:12px;margin:0 0 6px}
  input{width:100%;padding:12px;border-radius:10px;border:1px solid var(--line);background:#0b1220;color:var(--text);outline:none}
  input:focus{border-color:#3b82f6;box-shadow:0 0 0 3px rgba(59,130,246,.18)}
  .actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:10px}
  button{border:0;border-radius:10px;padding:11px 14px;font-weight:600;cursor:pointer}
  .primary{background:var(--btn);color:white}
  .secondary{background:var(--btn2);color:var(--text);border:1px solid var(--line)}
  .pill{display:inline-flex;align-items:center;gap:8px;padding:6px 10px;border-radius:999px;border:1px solid var(--line);color:var(--muted);font-size:12px}
  .status{margin-top:10px;font-size:12px}
  .ok{color:var(--ok)} .bad{color:var(--bad)} .warn{color:var(--warn)}
  .out{display:grid;gap:10px;margin-top:12px}
  .big{font-size:13px;color:var(--muted)}
  .linkbox{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
  .link{flex:1;min-width:260px;padding:12px;border-radius:10px;border:1px solid var(--line);background:#0b1220;color:var(--text)}
  .hint{color:var(--muted);font-size:12px;margin-top:6px}
  details{border:1px dashed var(--line);border-radius:12px;padding:10px}
  summary{cursor:pointer;color:var(--muted);font-weight:600}
  pre{white-space:pre-wrap;word-break:break-word;background:#0b1220;border:1px solid var(--line);border-radius:12px;padding:12px;margin:10px 0 0}
</style>
</head>
<body>
<div class="wrap">
  <div class="top">
    <div>
      <div class="brand">Provision Workspace</div>
      <div class="sub">Founder-only • creates a workspace + generates the single Pilot link for the agency.</div>
    </div>
    <div class="pill">Mode: <b>UX Easy</b></div>
  </div>

  <div class="grid">
    <div class="card">
      <div class="row">
        <div>
          <label>Workspace name</label>
          <input id="workspaceName" placeholder="e.g. Salam Agency" />
        </div>
        <div>
          <label>Agency email (optional)</label>
          <input id="agencyEmail" placeholder="agency@company.com" />
        </div>
      </div>

      <div class="actions">
        <button class="primary" id="createBtn">Create Workspace</button>
        <button class="secondary" id="clearBtn" type="button">Clear</button>
      </div>

      <div class="status" id="status"></div>

      <div class="out" id="out" style="display:none">
        <div class="big">Send to the agency:</div>

        <div class="linkbox">
          <input class="link" id="pilotLink" readonly />
          <button class="primary" id="copyPilotBtn" type="button">Copy Pilot Link</button>
        </div>

        <div class="hint">
          This is the only link the agency needs to start. Everything else is optional (Advanced).
        </div>

        <details>
          <summary>Advanced (webhook + extra links)</summary>
          <pre id="advancedBlock"></pre>
        </details>
      </div>
    </div>

    <div class="card">
      <div class="big">
        Tip: keep ADMIN_KEY only for founders. Agency never sees it.
      </div>
      <div class="hint">
        Open this page with: <code>/ui/admin/provision?adminKey=YOUR_ADMIN_KEY</code>
      </div>
    </div>
  </div>
</div>

<script>
  const $ = (id) => document.getElementById(id);

  function setStatus(msg, cls){
    const el = $("status");
    el.className = "status " + (cls || "");
    el.textContent = msg || "";
  }

  function buildAdvanced(json){
    // Only show what helps the agency integrate
    const lines = [];
    lines.push("Workspace created ✅");
    lines.push("");
    lines.push("PILOT:");
    lines.push(json?.links?.pilot || "");
    lines.push("");
    lines.push("WEBHOOK:");
    lines.push("URL: " + (json?.webhook?.url || ""));
    lines.push("Header: x-tenant-key: " + (json?.webhook?.headers?.["x-tenant-key"] || ""));
    lines.push("");
    lines.push("EXTRAS:");
    lines.push("Tickets: " + (json?.links?.tickets || ""));
    lines.push("Decisions: " + (json?.links?.decisions || ""));
    lines.push("CSV: " + (json?.links?.csv || ""));
    lines.push("ZIP: " + (json?.links?.zip || ""));
    return lines.join("\\n");
  }

  async function createWorkspace(){
    const workspaceName = ($("workspaceName").value || "").trim();
    const agencyEmail = ($("agencyEmail").value || "").trim();

    if(!workspaceName){
      setStatus("Please enter workspace name.", "warn");
      return;
    }

    const adminKeyFromQuery = ${JSON.stringify(adminKey)};
    const adminKey = adminKeyFromQuery || prompt("Admin key (founder only):") || "";
    if(!adminKey){
      setStatus("Missing admin key.", "bad");
      return;
    }

    setStatus("Creating…", "warn");
    $("out").style.display = "none";

    const url = new URL("/api/admin/provision", window.location.origin).toString();

    try{
      const resp = await fetch(url, {
        method: "POST",
        headers: {
          "content-type":"application/json",
          "x-admin-key": adminKey
        },
        body: JSON.stringify({ workspaceName, agencyEmail })
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

      const pilot = json?.links?.pilot || "";
      if(!pilot){
        setStatus("Created but missing pilot link in response.", "bad");
        return;
      }

      $("pilotLink").value = pilot;
      $("advancedBlock").textContent = buildAdvanced(json);
      $("out").style.display = "grid";
      setStatus("OK ✅ Workspace created. Copy the Pilot link and send it to the agency.", "ok");
    }catch(err){
      setStatus("Network/JS error: " + (err?.message || String(err)), "bad");
    }
  }

  $("createBtn").addEventListener("click", createWorkspace);
  $("clearBtn").addEventListener("click", () => {
    $("workspaceName").value = "";
    $("agencyEmail").value = "";
    $("pilotLink").value = "";
    $("advancedBlock").textContent = "";
    $("out").style.display = "none";
    setStatus("Cleared.", "warn");
  });

  $("copyPilotBtn").addEventListener("click", async () => {
    const v = $("pilotLink").value || "";
    if(!v) return;
    try{
      await navigator.clipboard.writeText(v);
      setStatus("Copied ✅", "ok");
    }catch{
      $("pilotLink").focus();
      $("pilotLink").select();
      document.execCommand("copy");
      setStatus("Copied ✅", "ok");
    }
  });
</script>
</body>
</html>`;

  res.status(200).type("html").send(html);
}
EOF

echo "OK: wrote $F (UX Easy admin provision page)"

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ UX mode applied"
echo "Backup: $BAK"
echo
echo "NEXT:"
echo "  kill -9 \$(lsof -t -iTCP:7090 -sTCP:LISTEN) 2>/dev/null || true"
echo "  ADMIN_KEY='dev_admin_key_123' bash scripts/dev_7090.sh"
echo "  open 'http://127.0.0.1:7090/ui/admin/provision?adminKey=dev_admin_key_123'"
