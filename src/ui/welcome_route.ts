import type { Express } from "express";

function esc(x: string) {
  return (x || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export function mountWelcome(app: Express) {
  app.get("/ui/welcome", (req, res) => {
    const tenantId = String((req.query as any).tenantId || "");
    const k = String((req.query as any).k || "");

    const proto = String((req.headers["x-forwarded-proto"] as any) || ((req.socket as any).encrypted ? "https" : "http"));
    const host = String((req.headers["x-forwarded-host"] as any) || req.headers.host || "localhost");
    const baseUrl = `${proto}://${host}`;

    const qs = tenantId && k ? `?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}` : "";

    const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Welcome — Decision Cover</title>
<style>
  :root{color-scheme:dark}
  body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1200px 800px at 30% 20%, #2b1055 0%, #0b0b12 55%, #05070c 100%);color:#e5e7eb}
  .wrap{max-width:980px;margin:42px auto;padding:0 18px}
  .card{border:1px solid rgba(255,255,255,.10);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
  h1{font-size:22px;margin:0 0 6px}
  .muted{color:#9ca3af;font-size:13px}
  .row{display:flex;gap:10px;flex-wrap:wrap;margin-top:10px}
  .pill{border:1px solid rgba(255,255,255,.12);background:rgba(0,0,0,.20);border-radius:999px;padding:6px 10px;font-size:12px}
  a{color:#c4b5fd;text-decoration:none}
  pre{white-space:pre-wrap;word-break:break-word;background:rgba(0,0,0,.35);border:1px solid rgba(255,255,255,.10);padding:12px;border-radius:12px}
  code{font-family:ui-monospace,Menlo,Monaco,Consolas,monospace;font-size:12px}
  .btn{display:inline-block;margin-top:10px;border:1px solid rgba(255,255,255,.18);background:rgba(139,92,246,.18);padding:10px 12px;border-radius:12px}
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Welcome — your workspace is ready ✅</h1>
      <div class="muted">This page is your “client-proof kit”: webhook → tickets → CSV export → evidence ZIP.</div>

      <div class="row">
        <div class="pill">baseUrl: <b>${esc(baseUrl)}</b></div>
        <div class="pill">tenantId: <b>${esc(tenantId || "—")}</b></div>
        <div class="pill">k: <b>${esc(k ? (k.slice(0,10)+"…") : "—")}</b></div>
      </div>

      <div class="muted" style="margin-top:14px">1) Setup (copy/paste for Zapier)</div>
      <pre><code>${esc(baseUrl)}/ui/setup${esc(qs)}</code></pre>
      <a class="btn" href="/ui/setup${qs}">Open Setup</a>

      <div class="muted" style="margin-top:14px">2) Tickets UI</div>
      <pre><code>${esc(baseUrl)}/ui/tickets${esc(qs)}</code></pre>

      <div class="muted" style="margin-top:14px">3) Export CSV</div>
      <pre><code>${esc(baseUrl)}/ui/export.csv${esc(qs)}</code></pre>

      <div class="muted" style="margin-top:14px">4) Evidence ZIP</div>
      <pre><code>${esc(baseUrl)}/ui/evidence.zip${esc(qs)}</code></pre>

      <div class="muted" style="margin-top:14px">Webhook endpoint</div>
      <pre><code>POST ${esc(baseUrl)}/api/webhook/intake
Content-Type: application/json</code></pre>

      <div class="muted" style="margin-top:14px">Done. If you lose this page, request a new link.</div>
    </div>
  </div>
</body>
</html>`;

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.setHeader("Cache-Control", "no-store");
    return res.status(200).send(html);
  });
}
