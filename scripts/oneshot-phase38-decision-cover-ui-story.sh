#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
BK="__bak_phase38_${TS}"
mkdir -p "$BK"

echo "==> Phase38 OneShot (Decision Cover™ UI Story) @ $ROOT"
echo "==> Backup -> $BK"

# ---- backup likely touched files
cp -v src/server.ts "$BK/" 2>/dev/null || true
cp -v src/ui/decisions.ts "$BK/" 2>/dev/null || true
cp -v src/ui/ui_shell.ts "$BK/" 2>/dev/null || true
cp -v src/ui/pages/decisions_story.ts "$BK/" 2>/dev/null || true
cp -v src/lib/decision/decision_store.ts "$BK/" 2>/dev/null || true

mkdir -p src/ui/pages src/ui public/ui

# ==========================================================
# [1] UI Shell (single-file HTML layout + styles + tiny JS)
# ==========================================================
cat > src/ui/ui_shell.ts <<'TS'
type ShellOpts = {
  title: string;
  description?: string;
  body: string;
  extraHead?: string;
  extraScript?: string;
};

export function uiShell(opts: ShellOpts) {
  const title = opts.title ?? "Decision Cover";
  const desc = opts.description ?? "";
  const headExtra = opts.extraHead ?? "";
  const scriptExtra = opts.extraScript ?? "";

  // NOTE: No external assets. Proof-first, privacy-first.
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>${escapeHtml(title)}</title>
  ${desc ? `<meta name="description" content="${escapeHtml(desc)}" />` : ""}

  <style>
    :root{
      color-scheme: dark;
      --bg0:#05070c;
      --bg1:#0b1633;
      --card: rgba(17,24,39,.62);
      --card2: rgba(17,24,39,.38);
      --line: rgba(255,255,255,.08);
      --text:#e5e7eb;
      --muted:#9ca3af;
      --brand:#7c3aed;
      --good:#22c55e;
      --warn:#f59e0b;
      --bad:#ef4444;
      --cyan:#22d3ee;
      --radius:18px;
    }

    *{ box-sizing:border-box; }
    body{
      margin:0;
      font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial;
      background:
        radial-gradient(1200px 800px at 30% 20%, var(--bg1) 0%, var(--bg0) 65%);
      color:var(--text);
    }
    a{ color:inherit; text-decoration:none; }
    .wrap{ max-width:1100px; margin:44px auto; padding:0 18px; }
    .top{
      display:flex; align-items:center; justify-content:space-between; gap:14px; margin-bottom:16px;
    }
    .brand{
      display:flex; align-items:center; gap:10px;
      padding:10px 12px;
      border:1px solid var(--line);
      border-radius:999px;
      background: rgba(0,0,0,.18);
      backdrop-filter: blur(10px);
    }
    .dot{
      width:10px; height:10px; border-radius:99px;
      background: linear-gradient(135deg, var(--brand), var(--cyan));
      box-shadow: 0 0 18px rgba(124,58,237,.45);
    }
    .brand b{ letter-spacing:.2px; }
    .pill{
      font-size:12px; color:var(--muted);
      border:1px solid var(--line);
      padding:8px 10px; border-radius:999px;
      background: rgba(0,0,0,.18);
    }

    .hero{
      border:1px solid var(--line);
      border-radius: var(--radius);
      background: linear-gradient(180deg, rgba(124,58,237,.16), rgba(0,0,0,.12));
      padding:18px;
      box-shadow: 0 18px 60px rgba(0,0,0,.35);
      overflow:hidden;
      position:relative;
    }
    .hero:before{
      content:"";
      position:absolute; inset:-2px;
      background: radial-gradient(600px 220px at 20% 10%, rgba(34,211,238,.18), transparent 60%),
                  radial-gradient(600px 220px at 80% 40%, rgba(124,58,237,.22), transparent 60%);
      pointer-events:none;
    }
    .heroGrid{
      position:relative;
      display:grid;
      grid-template-columns: 1.25fr .75fr;
      gap:14px;
      align-items:start;
    }
    .h1{ font-size:28px; font-weight:900; margin:0 0 6px; letter-spacing:.2px; }
    .sub{ color:var(--muted); font-size:14px; line-height:1.5; margin:0; }
    .ctaRow{ display:flex; gap:10px; flex-wrap:wrap; margin-top:14px; }
    .btn{
      display:inline-flex; align-items:center; gap:8px;
      padding:10px 12px;
      border-radius: 12px;
      border:1px solid var(--line);
      background: rgba(0,0,0,.25);
      cursor:pointer;
      transition: transform .12s ease, border-color .12s ease;
      user-select:none;
    }
    .btn:hover{ transform: translateY(-1px); border-color: rgba(124,58,237,.55); }
    .btn.primary{
      background: linear-gradient(135deg, rgba(124,58,237,.75), rgba(34,211,238,.35));
      border-color: rgba(124,58,237,.55);
    }
    .btn small{ color: rgba(255,255,255,.85); font-weight:700; }
    .btn .mut{ font-size:12px; color: rgba(255,255,255,.85); opacity:.9; font-weight:700; }

    .grid{
      margin-top:14px;
      display:grid;
      grid-template-columns: 1fr 1fr;
      gap:14px;
    }
    .card{
      border:1px solid var(--line);
      border-radius: var(--radius);
      background: var(--card);
      backdrop-filter: blur(12px);
      padding:16px;
      box-shadow: 0 18px 60px rgba(0,0,0,.22);
    }
    .card h2{ margin:0 0 6px; font-size:16px; font-weight:900; }
    .muted{ color:var(--muted); font-size:13px; }
    .row{ display:flex; gap:10px; flex-wrap:wrap; align-items:center; }
    .kpi{
      border:1px solid var(--line);
      background: rgba(0,0,0,.18);
      padding:10px 12px; border-radius:14px;
      min-width: 140px;
    }
    .kpi .v{ font-size:16px; font-weight:900; }
    .kpi .l{ font-size:12px; color:var(--muted); margin-top:2px; }

    /* Flow animation */
    .flow{
      margin-top:10px;
      display:grid;
      grid-template-columns: repeat(4, 1fr);
      gap:10px;
    }
    .step{
      border:1px solid var(--line);
      background: var(--card2);
      border-radius: 16px;
      padding:12px;
      position:relative;
      overflow:hidden;
      min-height: 88px;
    }
    .step:before{
      content:"";
      position:absolute; inset:0;
      background: linear-gradient(90deg, transparent, rgba(124,58,237,.18), transparent);
      transform: translateX(-110%);
      animation: sweep 2.6s ease-in-out infinite;
      pointer-events:none;
    }
    .step:nth-child(2):before{ animation-delay: .25s; }
    .step:nth-child(3):before{ animation-delay: .5s; }
    .step:nth-child(4):before{ animation-delay: .75s; }
    @keyframes sweep{
      0%{ transform: translateX(-110%); opacity:0; }
      15%{ opacity:1; }
      50%{ transform: translateX(110%); opacity:1; }
      100%{ transform: translateX(110%); opacity:0; }
    }
    .step .t{ font-weight:900; }
    .step .d{ margin-top:6px; color:var(--muted); font-size:12px; line-height:1.35; }

    .badge{
      display:inline-flex; align-items:center; gap:6px;
      font-size:12px; font-weight:900;
      border:1px solid var(--line);
      background: rgba(0,0,0,.18);
      padding:6px 10px; border-radius:999px;
    }
    .dot2{ width:8px; height:8px; border-radius:999px; }
    .good{ background:var(--good); }
    .warn{ background:var(--warn); }
    .bad{ background:var(--bad); }

    .list{ margin-top:10px; display:flex; flex-direction:column; gap:10px; }
    .item{
      border:1px solid var(--line);
      background: rgba(0,0,0,.18);
      border-radius: 16px;
      padding:12px;
    }
    .itemHead{ display:flex; align-items:center; justify-content:space-between; gap:10px; }
    .itemHead b{ font-size:14px; }
    .item pre{
      margin:10px 0 0;
      white-space: pre-wrap;
      word-break: break-word;
      background: rgba(0,0,0,.28);
      border:1px solid var(--line);
      padding:10px;
      border-radius: 12px;
      color: rgba(229,231,235,.92);
      font-size: 12px;
      display:none;
    }
    .item.open pre{ display:block; }

    .foot{
      margin-top:16px;
      color:var(--muted);
      font-size:12px;
      text-align:center;
      opacity:.95;
    }

    @media (max-width: 900px){
      .heroGrid{ grid-template-columns: 1fr; }
      .grid{ grid-template-columns: 1fr; }
      .flow{ grid-template-columns: 1fr 1fr; }
    }
  </style>

  ${headExtra}
</head>
<body>
  <div class="wrap">
    ${opts.body}
    <div class="foot">
      Decision Cover™ • Proof-first decisions • No keys stored in UI • Vendor-neutral
    </div>
  </div>

  <script>
    // Expand/collapse items
    document.addEventListener('click', (e) => {
      const el = e.target;
      const row = el && el.closest ? el.closest('[data-toggle="item"]') : null;
      if (!row) return;
      row.classList.toggle('open');
    });

    // Copy share link
    document.addEventListener('click', async (e) => {
      const el = e.target;
      const btn = el && el.closest ? el.closest('[data-copy]') : null;
      if (!btn) return;
      const val = btn.getAttribute('data-copy') || '';
      try{
        await navigator.clipboard.writeText(val);
        btn.innerHTML = '✅ Copied';
        setTimeout(() => { btn.innerHTML = 'Copy Share Link'; }, 1200);
      } catch {}
    });
  </script>

  ${scriptExtra}
</body>
</html>`;
}

function escapeHtml(s: string) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
TS

# ==========================================================
# [2] Decision store helper (ensure list + safe read)
# ==========================================================
cat > src/lib/decision/decision_store.ts <<'TS'
import fs from "node:fs/promises";
import path from "node:path";

export type DecisionRecord = {
  id: string;
  tenantId: string;
  createdAt: string;
  title?: string;
  tier?: "GREEN" | "AMBER" | "RED" | "PURPLE" | string;
  score?: number;
  reason?: string;
  actions?: string[];
  signals?: Record<string, any>;
  evidence?: {
    zipPath?: string;
    csvPath?: string;
    hash?: string;
  };
  raw?: any;
};

function dataDir() {
  return process.env.DATA_DIR || "./data";
}

function decisionsFile(tenantId: string) {
  return path.join(process.cwd(), dataDir(), "tenants", tenantId, "decisions.jsonl");
}

async function readJsonlSafe(file: string): Promise<any[]> {
  try {
    const raw = await fs.readFile(file, "utf8");
    const lines = raw.split("\n").map((l) => l.trim()).filter(Boolean);
    const out: any[] = [];
    for (const l of lines) {
      try { out.push(JSON.parse(l)); } catch {}
    }
    return out;
  } catch {
    return [];
  }
}

export async function listDecisions(tenantId: string, limit = 25): Promise<DecisionRecord[]> {
  const file = decisionsFile(tenantId);
  const rows = await readJsonlSafe(file);

  const mapped = rows
    .map((r, idx) => {
      const id = String(r.id || r.decisionId || r.runId || `${idx}`);
      const createdAt = String(r.createdAt || r.ts || r.time || new Date().toISOString());
      const tier = r.tier || r.status?.tier || r.decision?.tier;
      const score = Number(r.score ?? r.status?.score ?? r.decision?.score ?? 0);
      const reason = r.reason || r.decision?.reason || r.status?.reason || "";
      const actions = Array.isArray(r.actions) ? r.actions : (Array.isArray(r.decision?.actions) ? r.decision.actions : []);
      const signals = r.signals || r.decision?.signals || r.inputs || {};
      const title = r.title || r.decision?.title || r.subject || "Decision";
      const evidence = r.evidence || r.decision?.evidence || {};

      return {
        id,
        tenantId,
        createdAt,
        title,
        tier,
        score,
        reason,
        actions,
        signals,
        evidence,
        raw: r,
      } satisfies DecisionRecord;
    })
    .sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1))
    .slice(0, limit);

  return mapped;
}
TS

# ==========================================================
# [3] Decisions Story Page renderer
# ==========================================================
cat > src/ui/pages/decisions_story.ts <<'TS'
import { uiShell } from "../ui_shell";
import { listDecisions } from "../../lib/decision/decision_store";

function pickColor(tier?: string) {
  const t = String(tier || "").toUpperCase();
  if (t === "GREEN") return "good";
  if (t === "AMBER" || t === "YELLOW") return "warn";
  if (t === "RED") return "bad";
  return "warn";
}

function safeStr(x: any) {
  return (x === null || x === undefined) ? "" : String(x);
}

export async function renderDecisionsStory(opts: {
  baseUrl: string;
  tenantId: string;
  tenantKey: string;
}) {
  const { baseUrl, tenantId, tenantKey } = opts;

  const decisions = await listDecisions(tenantId, 25);
  const latest = decisions[0];

  const share = `${baseUrl}/ui/decisions?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;
  const zip = `${baseUrl}/ui/evidence.zip?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;
  const csv = `${baseUrl}/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;
  const tickets = `${baseUrl}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;

  const tier = safeStr(latest?.tier || "AMBER");
  const score = Number(latest?.score ?? 0);
  const reason = safeStr(latest?.reason || "No reason provided yet (create more decisions).");
  const actions = (latest?.actions && latest.actions.length ? latest.actions : [
    "Freeze risky changes until proof is complete",
    "Request missing evidence (owner + timestamp + source)",
    "Escalate to human review if uncertainty remains",
  ]);

  const signals = latest?.signals || {};
  const signalsPretty = JSON.stringify(signals, null, 2);

  const body = `
    <div class="top">
      <div class="brand">
        <span class="dot"></span>
        <div>
          <b>Decision Cover™</b>
        </div>
      </div>
      <div class="pill">tenant: <b style="color:#fff">${tenantId}</b></div>
    </div>

    <div class="hero">
      <div class="heroGrid">
        <div>
          <h1 class="h1">If you must decide, decide with proof.</h1>
          <p class="sub">
            A clean, vendor-neutral decision pipeline that turns messy input into a documented decision,
            with evidence you can export and share.
          </p>

          <div class="ctaRow">
            <a class="btn primary" href="${zip}">
              <small>Download Evidence ZIP</small>
            </a>
            <a class="btn" href="${csv}">
              <span class="mut">Export CSV</span>
            </a>
            <a class="btn" href="${tickets}">
              <span class="mut">View Tickets</span>
            </a>
            <button class="btn" data-copy="${share}">Copy Share Link</button>
          </div>

          <div class="flow">
            <div class="step">
              <div class="t">1) Intake</div>
              <div class="d">Collect the request + context (email/webhook/form).</div>
            </div>
            <div class="step">
              <div class="t">2) Normalize</div>
              <div class="d">Extract signals, remove noise, dedupe & tag.</div>
            </div>
            <div class="step">
              <div class="t">3) Decide</div>
              <div class="d">Tier + score + written reason + recommended actions.</div>
            </div>
            <div class="step">
              <div class="t">4) Evidence</div>
              <div class="d">ZIP/CSV you can share with client or auditors.</div>
            </div>
          </div>
        </div>

        <div class="card">
          <h2>Latest Decision</h2>
          <div class="row" style="margin-top:10px">
            <span class="badge"><span class="dot2 ${pickColor(tier)}"></span> ${tier}</span>
            <span class="badge">Score: ${isFinite(score) ? score : 0}</span>
          </div>

          <div class="muted" style="margin-top:10px">Reason</div>
          <div style="margin-top:6px; line-height:1.45">${escape(reason)}</div>

          <div class="muted" style="margin-top:12px">Recommended Actions</div>
          <div class="list">
            ${actions.map((a) => `<div class="item"><b>•</b> ${escape(a)}</div>`).join("")}
          </div>
        </div>
      </div>
    </div>

    <div class="grid">
      <div class="card">
        <h2>Signals (transparent)</h2>
        <div class="muted">We show the inputs that led to the decision. No black box promises.</div>
        <div class="item open" data-toggle="item" style="margin-top:10px">
          <div class="itemHead">
            <b>Latest signals</b>
            <span class="muted">click to toggle</span>
          </div>
          <pre>${escape(signalsPretty)}</pre>
        </div>
        <div class="muted" style="margin-top:10px">
          Tip: feed more structured intake → cleaner signals → stronger evidence.
        </div>
      </div>

      <div class="card">
        <h2>Evidence Pack</h2>
        <div class="muted">
          Share proof instead of promises. ZIP can include decision JSON, ticket snapshot, and exports.
        </div>

        <div class="row" style="margin-top:12px">
          <a class="btn primary" href="${zip}"><small>Evidence ZIP</small></a>
          <a class="btn" href="${csv}"><span class="mut">CSV Export</span></a>
        </div>

        <div style="margin-top:12px" class="muted">
          Integrity note: we avoid embedding secrets in UI. Tenant key is a link-token for the demo client view.
        </div>

        <div class="row" style="margin-top:12px">
          <div class="kpi">
            <div class="v">${decisions.length}</div>
            <div class="l">Decisions in timeline</div>
          </div>
          <div class="kpi">
            <div class="v">${escape(tier)}</div>
            <div class="l">Current tier</div>
          </div>
        </div>
      </div>
    </div>

    <div class="card" style="margin-top:14px">
      <h2>Decision Timeline</h2>
      <div class="muted">Click an item to expand raw record (proof-first debugging).</div>

      <div class="list" style="margin-top:10px">
        ${
          decisions.length
            ? decisions.map((d) => {
                const t = safeStr(d.tier || "AMBER");
                const c = pickColor(t);
                const when = safeStr(d.createdAt);
                const title = safeStr(d.title || "Decision");
                const raw = JSON.stringify(d.raw ?? d, null, 2);
                return `
                  <div class="item" data-toggle="item">
                    <div class="itemHead">
                      <div class="row">
                        <span class="badge"><span class="dot2 ${c}"></span> ${escape(t)}</span>
                        <b>${escape(title)}</b>
                      </div>
                      <span class="muted">${escape(when)}</span>
                    </div>
                    <pre>${escape(raw)}</pre>
                  </div>
                `;
              }).join("")
            : `<div class="item"><b>No decisions yet.</b> Create some runs then refresh this page.</div>`
        }
      </div>
    </div>
  `;

  return uiShell({
    title: "Decision Cover — Decisions",
    description: "Proof-first decision timeline + evidence export.",
    body,
  });
}

function escape(s: string) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
TS

# ==========================================================
# [4] /ui/decisions handler (wire to story renderer)
#    - If src/ui/decisions.ts exists, overwrite safely
# ==========================================================
cat > src/ui/decisions.ts <<'TS'
import type { Request, Response } from "express";
import { renderDecisionsStory } from "./pages/decisions_story";

function baseUrlFromReq(req: any) {
  const proto = (req.headers["x-forwarded-proto"] || "http").toString();
  const host = (req.headers["x-forwarded-host"] || req.headers.host || "127.0.0.1:7090").toString();
  return `${proto}://${host}`;
}

export async function uiDecisionsHandler(req: Request, res: Response) {
  const tenantId = String(req.query.tenantId || "").trim();
  const tenantKey = String(req.query.k || "").trim();

  if (!tenantId || !tenantKey) {
    res.status(400).type("text/plain").send("missing tenantId or k");
    return;
  }

  try {
    const html = await renderDecisionsStory({
      baseUrl: baseUrlFromReq(req),
      tenantId,
      tenantKey,
    });

    res.status(200).setHeader("Content-Type", "text/html; charset=utf-8").send(html);
  } catch (err: any) {
    res.status(500).type("text/plain").send(err?.message || "ui_decisions_failed");
  }
}
TS

# ==========================================================
# [5] Patch src/server.ts to ensure route is mounted
#     We do a minimal, additive patch:
#     - import { uiDecisionsHandler } from "./ui/decisions";
#     - app.get("/ui/decisions", uiDecisionsHandler);
# ==========================================================
node <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
if (!fs.existsSync(p)) {
  console.error("ERROR: src/server.ts not found");
  process.exit(1);
}
let s = fs.readFileSync(p, "utf8");

// add import if missing
if (!s.includes("uiDecisionsHandler")) {
  // try insert near other ui imports
  const importLine = `import { uiDecisionsHandler } from "./ui/decisions";\n`;
  if (s.includes('from "./ui/')) {
    // insert after last ui import
    const lines = s.split("\n");
    let idx = -1;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].includes('from "./ui/')) idx = i;
    }
    if (idx >= 0) {
      lines.splice(idx + 1, 0, importLine.trimEnd());
      s = lines.join("\n");
    } else {
      s = importLine + s;
    }
  } else {
    s = importLine + s;
  }
}

// add route if missing
if (!s.includes('"/ui/decisions"')) {
  // insert near other /ui routes if exist
  const needle = 'app.get("/ui/';
  const i = s.indexOf(needle);
  if (i >= 0) {
    // place before first ui route
    const ins = `app.get("/ui/decisions", uiDecisionsHandler);\n`;
    s = s.slice(0, i) + ins + s.slice(i);
  } else {
    // fallback: insert before listen/export
    const ins = `\n// Decision Cover™ UI Story\napp.get("/ui/decisions", uiDecisionsHandler);\n`;
    const j = s.lastIndexOf("app.listen");
    if (j >= 0) s = s.slice(0, j) + ins + s.slice(j);
    else s += ins;
  }
}

fs.writeFileSync(p, s);
console.log("✅ Patched src/server.ts (mounted /ui/decisions)");
NODE

# ==========================================================
# [6] Smoke script Phase38
# ==========================================================
cat > scripts/smoke-phase38.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:?missing ADMIN_KEY}"

fail(){ echo "FAIL: $*"; exit 1; }

echo "BASE_URL=$BASE_URL"

echo "==> health"
curl -fsS "$BASE_URL/health" >/dev/null || fail "health failed"

echo "==> Location from /ui/admin"
HDRS="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | tr -d '\r')"
LOC="$(printf "%s\n" "$HDRS" | sed -n 's/^[Ll]ocation: //p' | head -n1)"
[ -n "$LOC" ] || fail "no Location header"

Q="${LOC#*\?}"
TENANT_ID="$(printf "%s\n" "$Q" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(printf "%s\n" "$Q" | sed -n 's/.*k=\([^&]*\).*/\1/p')"
[ -n "$TENANT_ID" ] || fail "tenantId parse failed"
[ -n "$TENANT_KEY" ] || fail "k parse failed"

DECISIONS="$BASE_URL/ui/decisions?tenantId=$TENANT_ID&k=$TENANT_KEY"

echo "==> ui/decisions 200"
curl -s -o /dev/null -w "%{http_code}" "$DECISIONS" | grep -q 200 || fail "ui/decisions not 200"

echo "✅ Phase38 smoke OK"
echo "UI:"
echo "  $DECISIONS"
SH
chmod +x scripts/smoke-phase38.sh

echo
echo "✅ Phase38 installed."
echo "Now:"
echo "  (A) ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  (B) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase38.sh"
