type ReceiptArgs = {
  to: string;
  subject: string;
  ticketId: string;
  tenantId: string;
  dueAtISO?: string;
  slaSeconds?: number;
  priority?: string;
  status?: string;
  shareUrl?: string;
};

function esc(s: string) {
  return String(s || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export class ResendMailer {
  private apiKey?: string;
  private from?: string;
  private publicBaseUrl?: string;
  private dryRun?: boolean;

  constructor(args: { apiKey?: string; from?: string; publicBaseUrl?: string; dryRun?: boolean }) {
    this.apiKey = args.apiKey;
    this.from = args.from;
    this.publicBaseUrl = args.publicBaseUrl;
    this.dryRun = args.dryRun;
  }

  isConfigured() {
    return !!(this.apiKey && this.from);
  }

  async sendReceipt(args: ReceiptArgs) {
    if (!this.isConfigured()) return { ok: false, error: "resend_not_configured" as const };
    if (this.dryRun) {
      // safe mode: never sends, but returns ok
      return { ok: true, dryRun: true as const };
    }

    const html = `
      <div style="font-family: ui-sans-serif, system-ui; line-height:1.4">
        <h2 style="margin:0 0 12px">✅ Ticket created</h2>
        <p style="margin:0 0 8px">Ticket ID: <b>${esc(args.ticketId)}</b></p>
        <p style="margin:0 0 8px">Priority: <b>${esc(args.priority || "unknown")}</b> · Status: <b>${esc(args.status || "new")}</b></p>
        <p style="margin:0 0 8px">Due: <b>${esc(args.dueAtISO || "-")}</b></p>
        ${args.shareUrl ? `<p style="margin:12px 0 0"><a href="${esc(args.shareUrl)}">Open tickets dashboard</a></p>` : ""}
        <hr style="margin:16px 0;border:none;border-top:1px solid #eee"/>
        <p style="color:#666;font-size:12px;margin:0">Intake-Guardian • proof UI (MVP)</p>
      </div>
    `.trim();

    const payload = {
      from: this.from,
      to: args.to,
      subject: args.subject,
      html,
    };

    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${this.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });

    if (!r.ok) {
      const txt = await r.text().catch(() => "");
      return { ok: false as const, error: "resend_send_failed" as const, status: r.status, body: txt };
    }

    return { ok: true as const };
  }
  // Compatibility alias (older code)
  async sendTicketReceipt(payload: any) {
    // prefer sendReceipt if present
    return this.sendReceipt(payload);
  }

}
