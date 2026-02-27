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
