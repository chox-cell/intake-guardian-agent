#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date +%Y%m%d_%H%M%S)"
BK="__bak_phase29_${TS}"
mkdir -p "$BK"

echo "==> Phase29 OneShot (fix evidence.zip 500 via ditto/zip fallback) @ $ROOT"
echo "==> Backup -> $BK"
cp -R src "$BK/src" 2>/dev/null || true
cp -R scripts "$BK/scripts" 2>/dev/null || true
cp -f tsconfig.json "$BK/tsconfig.json" 2>/dev/null || true

# -------------------------
# [1] Patch src/ui/routes.ts
# - add createZipPortable()
# - use it in buildEvidenceZip()
# - show error details in 500 page
# -------------------------
cat > src/ui/routes.ts <<'TS'
import type { Express } from "express";
import path from "node:path";
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { verifyTenantKeyLocal, getOrCreateDemoTenant } from "../lib/tenant_registry.js";
import { listTickets, setTicketStatus, type TicketRecord, type TicketStatus } from "../lib/tickets_pipeline.js";
import { ensureDir, safeEncode } from "../lib/_util.js";

function htmlPage(title: string, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>${title}</title>
<style>
  :root{
    --bg:#070A12;
    --card: rgba(17,24,39,.55);
    --line: rgba(255,255,255,.08);
    --muted:#9ca3af;
    --txt:#e5e7eb;
    --shadow: 0 18px 60px rgba(0,0,0,.35);
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
  .wrap{ max-width: 1180px; margin: 56px auto; padding: 0 18px; }
  .card{
    border:1px solid var(--line);
    background: var(--card);
    border-radius: 18px;
    padding: 18px 18px;
    box-shadow: var(--shadow);
  }
  .h{ font-size: 28px; font-weight: 850; margin: 0 0 8px; letter-spacing: .2px; }
  .muted{ color:var(--muted); font-size: 13px; }
  .row{ display:flex; gap:12px; flex-wrap:wrap; align-items:center; margin-top: 12px; }
  .btn{
    display:inline-flex; align-items:center; gap:8px;
    padding:10px 14px; border-radius: 12px;
    border:1px solid rgba(255,255,255,.10);
    background: rgba(0,0,0,.25);
    color:var(--txt); text-decoration:none; font-weight:800;
    cursor:pointer;
  }
  .btn:hover{ border-color: rgba(255,255,255,.18); background: rgba(0,0,0,.34); }
  .btn.primary{ background: rgba(34,197,94,.16); border-color: rgba(34,197,94,.30); }
  .btn.primary:hover{ background: rgba(34,197,94,.22); }
  table{ width:100%; border-collapse: collapse; margin-top: 12px; }
  th,td{ text-align:left; padding: 10px 10px; border-bottom: 1px solid rgba(255,255,255,.06); font-size: 13px; }
  th{ color:var(--muted); font-weight: 900; font-size: 12px; letter-spacing: .08em; text-transform: uppercase; }
  .chip{
    display:inline-flex; align-items:center; gap:8px;
    padding: 4px 10px;
    border-radius: 999px;
    border:1px solid rgba(255,255,255,.10);
    background: rgba(0,0,0,.20);
    font-weight: 900;
    font-size: 12px;
    text-decoration:none;
    color: var(--txt);
  }
  .chip.open{ border-color: rgba(59,130,246,.35); background: rgba(59,130,246,.12); }
  .chip.pending{ border-color: rgba(245,158,11,.35); background: rgba(245,158,11,.12); }
  .chip.closed{ border-color: rgba(34,197,94,.35); background: rgba(34,197,94,.12); }
  .mono{ font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; }
  .right{ margin-left:auto; }
  .small{ font-size: 12px; color: var(--muted); }
  pre{ white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
</style>
</head>
<body>
  <div class="wrap">
    ${body}
  </div>
</body>
</html>`;
}

function bad(res: any, msg: string, hint = "") {
  return res.status(400).send(htmlPage("Error", `
    <div class="card">
      <div class="h">Error</div>
      <div class="muted">${msg}</div>
      ${hint ? `<pre class="mono">${hint}</pre>` : ""}
    </div>
  `));
}

function getTenantFromReq(req: any) {
  const tenantId = String(req.query.tenantId || "").trim();
  const tenantKey = String(req.query.k || req.query.tenantKey || "").trim();
  return { tenantId, tenantKey };
}

function mustAuth(req: any, res: any) {
  const { tenantId, tenantKey } = getTenantFromReq(req);
  if (!tenantId || !tenantKey) {
    bad(res, "missing tenantId/k", "Use: /ui/tickets?tenantId=...&k=...");
    return null;
  }
  if (!verifyTenantKeyLocal(tenantId, tenantKey)) {
    res.status(401).send(htmlPage("Unauthorized", `
      <div class="card">
        <div class="h">Unauthorized</div>
        <div class="muted">invalid_tenant_key</div>
      </div>
    `));
    return null;
  }
  return { tenantId, tenantKey };
}

function csvEscape(s: string) {
  const v = String(s ?? "");
  if (v.includes(",") || v.includes('"') || v.includes("\n")) return `"${v.replace(/"/g, '""')}"`;
  return v;
}

function ticketsToCsv(rows: TicketRecord[]) {
  const head = ["id","status","source","title","createdAtUtc","evidenceHash"].join(",");
  const lines = rows.map(t => [
    t.id, t.status, t.source, t.title, t.createdAtUtc, t.evidenceHash
  ].map(csvEscape).join(","));
  return [head, ...lines].join("\n") + "\n";
}

function commandExists(cmd: string): boolean {
  try {
    execFileSync("command", ["-v", cmd], { stdio: "ignore", shell: true });
    return true;
  } catch {
    return false;
  }
}

function createZipPortable(srcDir: string, outZip: string): { tool: string } {
  // macOS: ditto is extremely reliable. zip may fail if PATH is restricted.
  // Try ditto first if available; fallback to zip.
  const outDir = path.dirname(outZip);
  ensureDir(outDir);

  const dittoOk = commandExists("ditto");
  if (dittoOk) {
    // ditto -c -k --sequesterRsrc --keepParent <srcDir> <outZip>
    execFileSync("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", srcDir, outZip], { stdio: "ignore" });
    return { tool: "ditto" };
  }

  const zipOk = commandExists("zip");
  if (zipOk) {
    // zip -r <outZip> .   (cwd=srcDir)
    execFileSync("zip", ["-r", outZip, "."], { cwd: srcDir, stdio: "ignore" });
    return { tool: "zip" };
  }

  throw new Error("No archiver found: neither `ditto` nor `zip` available in PATH.");
}

function buildEvidenceZip(tenantId: string): { zipPath: string; tool: string } {
  const dataDir = process.env.DATA_DIR || "./data";
  const outDir = path.join(dataDir, "exports", tenantId);
  ensureDir(outDir);

  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const workDir = path.join(outDir, `pack_${stamp}`);
  ensureDir(workDir);

  const rows = listTickets(tenantId);
  fs.writeFileSync(path.join(workDir, "tickets.csv"), ticketsToCsv(rows), "utf8");

  const readme = [
    "# Intake-Guardian Evidence Pack",
    "",
    `tenantId: ${tenantId}`,
    `generatedAtUtc: ${new Date().toISOString()}`,
    "",
    "Contents:",
    "- tickets.csv",
    "- evidence/ (per-ticket evidence + raw payload if present)",
    "",
    "Notes:",
    "- Generated locally from disk storage.",
    "- Do not share tenant keys publicly.",
    ""
  ].join("\n");
  fs.writeFileSync(path.join(workDir, "README.md"), readme, "utf8");

  const evSrc = path.join(dataDir, "tenants", tenantId, "evidence");
  const evDst = path.join(workDir, "evidence");
  ensureDir(evDst);
  if (fs.existsSync(evSrc)) {
    for (const f of fs.readdirSync(evSrc)) {
      const src = path.join(evSrc, f);
      const dst = path.join(evDst, f);
      try { fs.copyFileSync(src, dst); } catch {}
    }
  }

  const zipPath = path.join(outDir, `evidence_pack_${tenantId}_${stamp}.zip`);
  const { tool } = createZipPortable(workDir, zipPath);

  return { zipPath, tool };
}

export function mountUi(app: Express) {
  app.get("/ui", (_req, res) => res.status(404).send("not found"));

  app.get("/ui/admin", async (req, res) => {
    try {
      const admin = String(req.query.admin || "");
      const ADMIN_KEY = String(process.env.ADMIN_KEY || "");
      if (!ADMIN_KEY || admin !== ADMIN_KEY) {
        return res.status(401).send(htmlPage("Unauthorized", `
          <div class="card">
            <div class="h">Unauthorized</div>
            <div class="muted">admin_key_required</div>
          </div>
        `));
      }

      const tenant = await getOrCreateDemoTenant();
      const loc = `/ui/tickets?tenantId=${safeEncode(tenant.tenantId)}&k=${safeEncode(tenant.tenantKey)}`;
      res.setHeader("Location", loc);
      return res.status(302).end();
    } catch (e: any) {
      return res.status(500).send(htmlPage("Admin error", `
        <div class="card">
          <div class="h">Admin error</div>
          <div class="muted">autolink_failed</div>
          <pre class="mono">${String(e?.stack || e?.message || e)}</pre>
        </div>
      `));
    }
  });

  app.get("/ui/tickets", (req, res) => {
    const auth = mustAuth(req, res);
    if (!auth) return;

    const { tenantId, tenantKey } = auth;
    const rows = listTickets(tenantId);

    const csvUrl = `/ui/export.csv?tenantId=${safeEncode(tenantId)}&k=${safeEncode(tenantKey)}`;
    const zipUrl = `/ui/evidence.zip?tenantId=${safeEncode(tenantId)}&k=${safeEncode(tenantKey)}`;

    const tableRows = rows.map(t => {
      const chip = `<span class="chip ${t.status}">${t.status}</span>`;
      const actions = [
        statusLink(tenantId, tenantKey, t.id, "open"),
        statusLink(tenantId, tenantKey, t.id, "pending"),
        statusLink(tenantId, tenantKey, t.id, "closed"),
      ].join(" ");

      return `<tr>
        <td class="mono">${t.id}</td>
        <td>${chip}</td>
        <td>${escapeHtml(t.source)}</td>
        <td>${escapeHtml(t.title)}</td>
        <td class="mono">${escapeHtml(t.createdAtUtc)}</td>
        <td>${actions}</td>
      </tr>`;
    }).join("");

    const body = `
      <div class="card">
        <div class="h">Tickets</div>
        <div class="muted">Client view • tenant <span class="mono">${escapeHtml(tenantId)}</span></div>

        <div class="row">
          <a class="btn primary" href="${zipUrl}">Download Evidence Pack (ZIP)</a>
          <a class="btn" href="${csvUrl}">Export CSV</a>
          <div class="right small">Tip: click a status to set it.</div>
        </div>

        <table>
          <thead>
            <tr>
              <th>ID</th><th>Status</th><th>Source</th><th>Title</th><th>Created</th><th>Set Status</th>
            </tr>
          </thead>
          <tbody>
            ${tableRows || `<tr><td colspan="6" class="muted">No tickets yet. Send a webhook to create one.</td></tr>`}
          </tbody>
        </table>

        <div class="small" style="margin-top:10px;">Intake-Guardian • ${new Date().toISOString()}</div>
      </div>
    `;

    res.status(200).send(htmlPage("Tickets", body));
  });

  app.get("/ui/export.csv", (req, res) => {
    const auth = mustAuth(req, res);
    if (!auth) return;
    const rows = listTickets(auth.tenantId);
    const csv = ticketsToCsv(rows);
    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${auth.tenantId}.csv"`);
    return res.status(200).send(csv);
  });

  app.get("/ui/evidence.zip", (req, res) => {
    const auth = mustAuth(req, res);
    if (!auth) return;
    try {
      const { zipPath, tool } = buildEvidenceZip(auth.tenantId);
      res.setHeader("X-Pack-Tool", tool);
      res.setHeader("Content-Type", "application/zip");
      res.setHeader("Content-Disposition", `attachment; filename="${path.basename(zipPath)}"`);
      fs.createReadStream(zipPath).pipe(res);
    } catch (e: any) {
      return res.status(500).send(htmlPage("Error", `
        <div class="card">
          <div class="h">Export error</div>
          <div class="muted">zip_failed</div>
          <pre class="mono">${escapeHtml(String(e?.stack || e?.message || e))}</pre>
          <div class="muted" style="margin-top:10px;">Tip: macOS should have <span class="mono">ditto</span>. If PATH is restricted, restart terminal and run again.</div>
        </div>
      `));
    }
  });

  app.get("/ui/set-status", (req, res) => {
    const auth = mustAuth(req, res);
    if (!auth) return;
    const id = String(req.query.id || "");
    const st = String(req.query.status || "");
    if (!id) return bad(res, "missing id");
    const status = (st === "pending" || st === "closed" || st === "open") ? (st as TicketStatus) : "open";
    setTicketStatus(auth.tenantId, id, status);
    const back = `/ui/tickets?tenantId=${safeEncode(auth.tenantId)}&k=${safeEncode(auth.tenantKey)}`;
    return res.redirect(302, back);
  });
}

function statusLink(tenantId: string, k: string, id: string, st: TicketStatus) {
  const href = `/ui/set-status?tenantId=${safeEncode(tenantId)}&k=${safeEncode(k)}&id=${safeEncode(id)}&status=${safeEncode(st)}`;
  return `<a class="chip ${st}" href="${href}">${st}</a>`;
}

function escapeHtml(s: string) {
  return String(s ?? "")
    .replace(/&/g,"&amp;")
    .replace(/</g,"&lt;")
    .replace(/>/g,"&gt;")
    .replace(/"/g,"&quot;")
    .replace(/'/g,"&#039;");
}
TS

# -------------------------
# [2] Smoke phase29 (copy phase28 smoke)
# -------------------------
cat > scripts/smoke-phase29.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $*" >&2; exit 1; }
say(){ echo "==> $*"; }

[ -n "$ADMIN_KEY" ] || fail "missing ADMIN_KEY. Use: ADMIN_KEY=... BASE_URL=... ./scripts/smoke-phase29.sh"

say "[0] health"
curl -sS "$BASE_URL/health" >/dev/null || fail "health not ok"
echo "✅ health ok"

say "[1] /ui hidden (404 expected)"
s1="$(curl -sS -D- -o /dev/null "$BASE_URL/ui" | head -n 1 | awk '{print $2}')"
echo "status=$s1"
[ "${s1:-}" = "404" ] || fail "/ui not 404"

say "[2] /ui/admin redirect (302 expected) + capture Location"
headers="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
loc="$(echo "$headers" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')"
[ -n "${loc:-}" ] || fail "no Location header from /ui/admin"
echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
[ -n "${TENANT_ID:-}" ] || fail "empty TENANT_ID"
[ -n "${TENANT_KEY:-}" ] || fail "empty TENANT_KEY"
echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

final="$BASE_URL$loc"
say "[3] tickets should be 200"
s3="$(curl -sS -D- "$final" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s3"
[ "${s3:-}" = "200" ] || fail "tickets not 200: $final"

say "[4] export.csv should be 200"
exportUrl="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
s4="$(curl -sS -D- "$exportUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s4"
[ "${s4:-}" = "200" ] || fail "export not 200: $exportUrl"

say "[5] evidence.zip should be 200"
zipUrl="$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY"
s5="$(curl -sS -D- "$zipUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s5"
[ "${s5:-}" = "200" ] || fail "zip not 200: $zipUrl"

say "[6] webhook intake should be 201 and dedupe on repeat"
payload='{"source":"webhook","title":"Webhook intake","message":"hello","externalId":"demo-123","priority":"medium","data":{"a":1}}'
w1="$(curl -sS -w "\n%{http_code}\n" -X POST "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Id: demo-123" \
  -d "$payload")"
code1="$(echo "$w1" | tail -n 1)"
body1="$(echo "$w1" | sed '$d')"
echo "status=$code1"
[ "$code1" = "201" ] || fail "webhook not 201: $body1"

w2="$(curl -sS -w "\n%{http_code}\n" -X POST "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Id: demo-123" \
  -d "$payload")"
code2="$(echo "$w2" | tail -n 1)"
body2="$(echo "$w2" | sed '$d')"
echo "status=$code2"
[ "$code2" = "201" ] || fail "webhook repeat not 201: $body2"

say "[7] tickets page should still be 200 after webhook"
s7="$(curl -sS -D- "$final" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s7"
[ "${s7:-}" = "200" ] || fail "tickets not 200 after webhook"

echo
echo "✅ Phase29 smoke OK"
echo "Client UI:"
echo "  $final"
echo "Export CSV:"
echo "  $exportUrl"
echo "Evidence ZIP:"
echo "  $zipUrl"
BASH
chmod +x scripts/smoke-phase29.sh
echo "✅ wrote scripts/smoke-phase29.sh"

# -------------------------
# [3] Typecheck (best effort)
# -------------------------
echo "==> Typecheck"
if pnpm -s lint:types >/dev/null 2>&1; then
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase29 installed."
echo "Now:"
echo "  1) restart: ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) smoke:   ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase29.sh"
