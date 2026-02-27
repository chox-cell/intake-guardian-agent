import type { Express, Request, Response } from "express";

function safeHtml(x: string) {
  return (x || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function getBaseUrl(req: Request) {
  const proto = String((req.headers["x-forwarded-proto"] as any) || ((req.socket as any).encrypted ? "https" : "http"));
  const host = String((req.headers["x-forwarded-host"] as any) || req.headers.host || "localhost");
  return `${proto}://${host}`;
}

export function mountPilotSalesPack(app: Express) {
  app.get("/ui/pilot", (req, res) => {
    const baseUrl = getBaseUrl(req);
    const tenantId = String((req.query as any).tenantId || "");
    const k = String((req.query as any).k || "");

    const has = Boolean(tenantId && k);
    const qs = has ? `tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}` : "";

    const links = has
      ? {
          welcome: `${baseUrl}/ui/welcome?${qs}`,
          decisions: `${baseUrl}/ui/decisions?${qs}`,
          tickets: `${baseUrl}/ui/tickets?${qs}`,
          setup: `${baseUrl}/ui/setup?${qs}`,
          csv: `${baseUrl}/ui/export.csv?${qs}`,
          zip: `${baseUrl}/ui/evidence.zip?${qs}`,
          webhook: `${baseUrl}/api/webhook/intake?tenantId=${encodeURIComponent(tenantId)}`,
        }
      : null;

    const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>Pilot Sales Pack</title>
<style>
  :root{color-scheme:dark}
  body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%);color:#e5e7eb}
  .wrap{max-width:980px;margin:40px auto;padding:0 18px}
  .card{border:1px solid rgba(255,255,255,.10);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
  .h{font-size:22px;font-weight:800;margin:0 0 6px}
  .muted{color:#9ca3af;font-size:13px}
  .row{display:flex;gap:10px;flex-wrap:wrap;margin-top:10px}
  .btn{display:inline-flex;align-items:center;justify-content:center;border:1px solid rgba(255,255,255,.12);background:rgba(99,102,241,.25);color:#fff;border-radius:12px;padding:10px 12px;font-weight:700;cursor:pointer;text-decoration:none}
  .btn.secondary{background:rgba(0,0,0,.25)}
  pre{white-space:pre-wrap;word-break:break-word;background:rgba(0,0,0,.35);border:1px solid rgba(255,255,255,.10);padding:12px;border-radius:12px}
  code{font-family:ui-monospace,Menlo,Monaco,Consolas,monospace;font-size:12px}
  .grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
  @media (max-width:900px){.grid{grid-template-columns:1fr}}
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="h">Pilot Sales Pack</div>
      <div class="muted">60 seconds: intake -> tickets -> export proof (CSV + ZIP).</div>

      <div class="row">
        <div class="muted">baseUrl: <b>${safeHtml(baseUrl)}</b></div>
        <div class="muted">tenantId: <b>${safeHtml(tenantId || "missing")}</b></div>
        <div class="muted">k: <b>${safeHtml(k ? (k.slice(0,10)+"...") : "missing")}</b></div>
      </div>

      ${has ? `
      <div class="row" style="margin-top:14px">
        <a class="btn" href="${safeHtml(links!.tickets)}">Open Tickets</a>
        <a class="btn secondary" href="${safeHtml(links!.decisions)}">Open Decisions</a>
        <a class="btn secondary" href="${safeHtml(links!.setup)}">Open Setup</a>
        <a class="btn secondary" href="${safeHtml(links!.csv)}">Download CSV</a>
        <a class="btn secondary" href="${safeHtml(links!.zip)}">Download Evidence ZIP</a>
      </div>

      <div class="muted" style="margin-top:14px">Zapier / Form POST (copy-paste):</div>
      <pre><code>URL: ${safeHtml(links!.webhook)}
Method: POST
Headers:
  Content-Type: application/json
  x-tenant-key: ${safeHtml(k)}

Body example:
{
  "source":"zapier",
  "type":"lead",
  "lead":{"fullName":"Jane Doe","email":"jane@example.com","company":"ACME"}
}</code></pre>

      <div class="muted" style="margin-top:10px">Quick test (one lead):</div>
      <pre><code>curl -sS -X POST "${safeHtml(links!.webhook)}" \\
  -H "content-type: application/json" \\
  -H "x-tenant-key: ${safeHtml(k)}" \\
  --data '{"source":"demo","type":"lead","lead":{"fullName":"Demo Lead","email":"demo@x.dev","company":"DemoCo"}}'</code></pre>
      ` : `
      <div class="muted" style="margin-top:14px">
        Missing tenantId + k. Open /ui/welcome (from email link) then come back with those query params.
      </div>
      `}
    </div>
  </div>
</body>
</html>`;

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.status(200).send(html);
  });
}
