#!/usr/bin/env bash
set -e

echo "==> Intake-Guardian UI v3 OneShot"

### 0) Paths
ROOT="$(pwd)"
SRC="$ROOT/src"
API="$SRC/api"
SHARE="$SRC/share"
SCRIPTS="$ROOT/scripts"

mkdir -p "$API" "$SHARE" "$SCRIPTS"

########################################
# 1) Share Token Store
########################################
cat > "$SHARE/store.ts" <<'TS'
import crypto from "crypto";

type ShareToken = {
  token: string;
  tenantId: string;
  expiresAt: number;
};

export class ShareStore {
  private items = new Map<string, ShareToken>();

  create(tenantId: string, ttlSeconds = 7 * 86400) {
    const token = crypto.randomBytes(18).toString("base64url");
    const expiresAt = Date.now() + ttlSeconds * 1000;
    this.items.set(token, { token, tenantId, expiresAt });
    return token;
  }

  verify(token: string) {
    const it = this.items.get(token);
    if (!it) return null;
    if (Date.now() > it.expiresAt) {
      this.items.delete(token);
      return null;
    }
    return it;
  }
}
TS

########################################
# 2) UI v3 (Tickets + KPIs + Export)
########################################
cat > "$API/ui.ts" <<'TS'
import { Router } from "express";
import { ShareStore } from "../share/store.js";

export function makeUiRoutes(args: any) {
  const r = Router();
  const shares = new ShareStore();

  r.get("/ui/tickets", async (req, res) => {
    const { tenantId, k } = req.query as any;
    if (!args.tenants.verify(tenantId, k)) {
      return res.status(401).send("invalid_tenant_key");
    }
    const items = args.store.list(tenantId, 100);
    const shareToken = shares.create(tenantId);
    res.send(render(items, tenantId, shareToken, false));
  });

  r.get("/ui/share/:token", async (req, res) => {
    const sh = shares.verify(req.params.token);
    if (!sh) return res.status(401).send("expired");
    const items = args.store.list(sh.tenantId, 100);
    res.send(render(items, sh.tenantId, null, true));
  });

  r.get("/ui/export.csv", async (req, res) => {
    const { tenantId, k } = req.query as any;
    if (!args.tenants.verify(tenantId, k)) {
      return res.status(401).send("invalid");
    }
    const rows = args.store.list(tenantId, 500);
    res.setHeader("Content-Type", "text/csv");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    res.write("id,subject,priority,status,dueAt,from\n");
    rows.forEach((r:any)=>{
      res.write(`${r.id},"${r.subject}",${r.priority},${r.status},${r.dueAt},${r.sender}\n`);
    });
    res.end();
  });

  return r;
}

function render(items:any[], tenantId:string, shareToken?:string|null, readOnly=false) {
  const now = Date.now();
  const kpis = {
    new: items.filter(i=>i.status==="new").length,
    progress: items.filter(i=>i.status==="in_progress").length,
    overdue: items.filter(i=>new Date(i.dueAt).getTime()<now && i.status!=="resolved").length,
    soon: items.filter(i=>new Date(i.dueAt).getTime()-now<4*3600*1000).length
  };

  return `<!doctype html>
<html>
<head>
<meta charset="utf-8"/>
<title>Tickets</title>
<style>
body{background:#0b0b0d;color:#eaeaf0;font-family:system-ui;margin:0}
.wrap{max-width:1100px;margin:30px auto;padding:0 20px}
.kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
.kpi{background:#111;border:1px solid #222;padding:14px;border-radius:12px}
table{width:100%;border-collapse:collapse;margin-top:20px}
th,td{padding:12px;border-bottom:1px solid #222;text-align:left}
.badge{padding:4px 10px;border-radius:999px;font-size:12px}
.high{background:#402}
.over{color:#f55}
.top{display:flex;justify-content:space-between;align-items:center}
a.btn{background:#1f7;color:#000;padding:8px 12px;border-radius:10px;text-decoration:none}
</style>
</head>
<body>
<div class="wrap">
<div class="top">
<h2>Tickets</h2>
${!readOnly ? `<a class="btn" href="/ui/export.csv?tenantId=${tenantId}&k=${'${k}'}">Export CSV</a>` : ``}
</div>

<div class="kpis">
<div class="kpi">New<br><b>${kpis.new}</b></div>
<div class="kpi">In progress<br><b>${kpis.progress}</b></div>
<div class="kpi">Overdue<br><b>${kpis.overdue}</b></div>
<div class="kpi">Due &lt; 4h<br><b>${kpis.soon}</b></div>
</div>

${shareToken ? `<p style="margin-top:14px;font-size:13px">
Share (read-only): <code>/ui/share/${shareToken}</code>
</p>` : ``}

<table>
<tr><th>ID</th><th>Subject</th><th>Priority</th><th>Status</th><th>Due</th><th>From</th></tr>
${items.map(i=>{
  const d=new Date(i.dueAt).getTime()-now;
  const due=d<0?`<span class="over">Overdue</span>`:`${Math.round(d/3600000)}h`;
  return `<tr>
<td>${i.id}</td>
<td>${i.subject}</td>
<td><span class="badge high">${i.priority}</span></td>
<td>${i.status}</td>
<td>${due}</td>
<td>${i.sender}</td>
</tr>`;
}).join("")}
</table>

<p style="opacity:.4;margin-top:40px">Intake-Guardian · Sellable MVP</p>
</div>
</body>
</html>`;
}
TS

########################################
# 3) Smoke test
########################################
cat > "$SCRIPTS/smoke-ui.sh" <<'SH'
#!/usr/bin/env bash
set -e
BASE="http://127.0.0.1:7090"

: "${TENANT_ID:?}"
: "${TENANT_KEY:?}"

curl -s "$BASE/health" | grep ok >/dev/null
curl -s "$BASE/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY" | grep Tickets >/dev/null
curl -s "$BASE/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY" | grep id,subject >/dev/null
echo "UI OK"
SH
chmod +x "$SCRIPTS/smoke-ui.sh"

########################################
# 4) Done
########################################
echo
echo "✅ UI v3 installed"
echo
echo "Next:"
echo "  pnpm dev"
echo "  export TENANT_ID=tenant_xxx"
echo "  export TENANT_KEY=xxxx"
echo "  open http://127.0.0.1:7090/ui/tickets?tenantId=\$TENANT_ID&k=\$TENANT_KEY"
echo "  scripts/smoke-ui.sh"
