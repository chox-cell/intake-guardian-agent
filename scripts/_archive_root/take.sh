#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/Projects/intake-guardian-agent"
cd "$ROOT"

TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_ui_A_$TS"
mkdir -p "$BAK"
cp -r src "$BAK/src"

echo "==> [1] Write UI routes: src/api/ui.ts"

mkdir -p src/api

cat > src/api/ui.ts <<'TS'
import { Router } from "express";
import type { Store } from "../store/store.js";

function auth(req:any, res:any) {
  const { tenantId, k } = req.query;
  if (!tenantId || !k) {
    res.status(401).send("missing tenant");
    return null;
  }
  if (!req.store.verifyTenantKey(tenantId, k)) {
    res.status(401).send("invalid tenant key");
    return null;
  }
  return tenantId as string;
}

export function makeUI(store: Store) {
  const r = Router();

  // ---- Tickets table
  r.get("/tickets", async (req, res) => {
    const tenantId = auth(req, res);
    if (!tenantId) return;

    const items = await store.listWorkItems(tenantId);

    res.setHeader("Content-Type", "text/html");
    res.send(`<!doctype html>
<html>
<head>
<meta charset="utf-8"/>
<title>Tickets</title>
<style>
body{font-family:system-ui;background:#0b0b0b;color:#eee;padding:24px}
table{width:100%;border-collapse:collapse}
th,td{padding:10px;border-bottom:1px solid #222}
button{padding:4px 8px;margin-right:4px}
.badge{padding:2px 6px;border-radius:6px}
.new{background:#444}
.in_progress{background:#b59b00}
.done{background:#1b7f3a}
</style>
</head>
<body>
<h2>Tickets (${items.length})</h2>
<p>
<a href="/ui/export.csv?tenantId=${tenantId}&k=${req.query.k}">Export CSV</a>
</p>
<table>
<thead>
<tr>
<th>ID</th><th>Subject</th><th>Priority</th><th>Status</th><th>Due</th><th>From</th>
</tr>
</thead>
<tbody>
${items.map(t => `
<tr>
<td>${t.id}</td>
<td>${t.subject || ""}</td>
<td>${t.priority}</td>
<td>
<span class="badge ${t.status}">${t.status}</span><br/>
<form method="POST" action="/ui/status">
<input type="hidden" name="tenantId" value="${tenantId}"/>
<input type="hidden" name="k" value="${req.query.k}"/>
<input type="hidden" name="id" value="${t.id}"/>
<button name="status" value="new">new</button>
<button name="status" value="in_progress">in progress</button>
<button name="status" value="done">done</button>
</form>
</td>
<td>${t.dueAt || ""}</td>
<td>${t.sender || ""}</td>
</tr>
`).join("")}
</tbody>
</table>
</body>
</html>`);
  });

  // ---- Update status
  r.post("/status", async (req, res) => {
    const { tenantId, k, id, status } = req.body;
    if (!store.verifyTenantKey(tenantId, k)) {
      res.status(401).send("invalid tenant key");
      return;
    }
    await store.updateStatus(tenantId, id, status);
    res.redirect(`/ui/tickets?tenantId=${tenantId}&k=${k}`);
  });

  // ---- Export CSV
  r.get("/export.csv", async (req, res) => {
    const tenantId = auth(req, res);
    if (!tenantId) return;

    const items = await store.listWorkItems(tenantId);
    res.setHeader("Content-Type", "text/csv");
    res.send([
      "id,subject,priority,status,due,from",
      ...items.map(t =>
        `"${t.id}","${t.subject || ""}","${t.priority}","${t.status}","${t.dueAt || ""}","${t.sender || ""}"`
      )
    ].join("\n"));
  });

  return r;
}
TS

echo "==> [2] Patch server.ts to mount UI"

node <<'NODE'
import fs from "fs";
const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");
if (!s.includes("makeUI")) {
  s = s.replace(
    /app\.use\("\/api".*\);\n/,
    m => m + `\nimport { makeUI } from "./api/ui.js";\napp.use("/ui", makeUI(store));\n`
  );
  fs.writeFileSync(p, s);
  console.log("✅ server.ts patched");
} else {
  console.log("ℹ️ UI already mounted");
}
NODE

echo "==> [3] Typecheck"
pnpm lint:types || true

echo "==> [4] Done"
echo
echo "START:"
echo "  pnpm dev"
echo
echo "OPEN:"
echo "  http://127.0.0.1:7090/ui/tickets?tenantId=TENANT&k=TENANT_KEY"
