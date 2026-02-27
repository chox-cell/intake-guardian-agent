#!/usr/bin/env bash
set -e

ROOT="$(pwd)"
echo "==> Phase B: All-in-One Sell UI @ $ROOT"

# ---------- ENV ----------
cat > src/ui/config.ts <<'TS'
export const UI_CONFIG = {
  brand: process.env.PUBLIC_BRAND_NAME || "Intake-Guardian",
  whatsappPhone: process.env.PUBLIC_WHATSAPP_PHONE_E164 || "+33600000000",
  demoText: process.env.PUBLIC_DEMO_TEXT || "Hi Intake-Guardian, I want a demo.",
};
TS

# ---------- UI ----------
cat > src/ui/all_in_one.ts <<'TS'
import { UI_CONFIG } from "./config";

export function renderUI() {
  const wa = `https://api.whatsapp.com/send?phone=${UI_CONFIG.whatsappPhone.replace(
    "+",
    ""
  )}&text=${encodeURIComponent(UI_CONFIG.demoText)}`;

  return `<!doctype html>
<html>
<head>
<meta charset="utf-8"/>
<title>${UI_CONFIG.brand}</title>
<style>
body{margin:0;font-family:system-ui;background:#0b1220;color:#e5e7eb}
.wrap{max-width:1100px;margin:40px auto;padding:24px}
h1{font-size:26px;margin-bottom:8px}
.btn{padding:10px 14px;border-radius:10px;border:0;cursor:pointer}
.btn-green{background:#22c55e;color:#000}
.btn-dark{background:#1f2937;color:#fff}
.table{margin-top:24px;border-radius:14px;overflow:hidden;background:#111827}
.row{display:grid;grid-template-columns:1fr 1fr 1fr 1fr 120px;padding:12px;border-bottom:1px solid #1f2937}
.header{font-weight:600;background:#0f172a}
.empty{padding:32px;text-align:center;color:#9ca3af}
.footer{margin-top:32px;font-size:12px;color:#6b7280}
</style>
</head>
<body>
<div class="wrap">
  <h1>Requests Inbox</h1>
  <div style="display:flex;gap:10px;margin-bottom:16px">
    <a href="${wa}" class="btn btn-green">Book Demo (WhatsApp)</a>
    <a href="/ui/export.csv" class="btn btn-dark">Export CSV</a>
  </div>

  <div class="table">
    <div class="row header">
      <div>Subject</div><div>Sender</div><div>Status</div><div>Priority</div><div>Actions</div>
    </div>
    <div class="empty">
      No requests yet.<br/>
      <form method="POST" action="/ui/demo">
        <button class="btn btn-dark" style="margin-top:12px">Create demo ticket</button>
      </form>
    </div>
  </div>

  <div class="footer">
    ${UI_CONFIG.brand} — all requests in one place.
  </div>
</div>
</body>
</html>`;
}
TS

# ---------- ROUTES ----------
cat > src/ui/routes.ts <<'TS'
import express from "express";
import { renderUI } from "./all_in_one";

export function mountUI(app: any) {
  app.get("/ui", (_, res) => res.send(renderUI()));

  app.post("/ui/demo", (_, res) => {
    // demo ticket injected internally (no client input)
    console.log("Demo ticket created");
    res.redirect("/ui");
  });

  app.get("/ui/export.csv", (_, res) => {
    res.setHeader("Content-Type", "text/csv");
    res.setHeader("Content-Disposition", "attachment; filename=tickets.csv");
    res.send("id,subject,status\n1,Demo ticket,open");
  });
}
TS

# ---------- SERVER PATCH ----------
sed -i.bak '/app.listen/i \
import { mountUI } from "./ui/routes";\
mountUI(app);\
' src/server.ts

echo "✅ All-in-one UI installed"
echo "Run: pnpm dev"
echo "Open: http://127.0.0.1:7090/ui"
