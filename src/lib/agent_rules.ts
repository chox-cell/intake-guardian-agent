import crypto from "crypto";

export type IntakeSource = "zapier" | "webhook" | "meta" | "typeform" | "calendly" | "unknown";

export type TicketStatus =
  | "new"
  | "needs_review"
  | "ready"
  | "duplicate";

export type TicketFlag =
  | "missing_email"
  | "missing_name"
  | "missing_contact"
  | "suspicious_payload"
  | "low_signal";

export type NormalizedLead = {
  fullName?: string;
  email?: string;
  phone?: string;
  company?: string;
  message?: string;
  raw?: any;
};

export type RulesResult = {
  status: TicketStatus;
  flags: TicketFlag[];
  missingFields: string[];
  title: string;
  fingerprint: string; // dedupeKey
};

function s(x: any): string {
  return (typeof x === "string" ? x : "").trim();
}

function pick(obj: any, keys: string[]): string {
  for (const k of keys) {
    const v = s(obj?.[k]);
    if (v) return v;
  }
  return "";
}

export function normalizeLead(body: any): { source: IntakeSource; type: string; lead: NormalizedLead } {
  const sourceRaw = s(body?.source).toLowerCase();
  const source: IntakeSource =
    (sourceRaw === "zapier" || sourceRaw === "meta" || sourceRaw === "typeform" || sourceRaw === "calendly") ? (sourceRaw as IntakeSource)
    : (sourceRaw ? "webhook" : "unknown");

  const type = s(body?.type) || "lead";
  const leadObj = body?.lead ?? body ?? {};

  const fullName =
    pick(leadObj, ["fullName", "name", "full_name", "fullname"]) ||
    [pick(leadObj, ["firstName","first_name","first"]), pick(leadObj, ["lastName","last_name","last"])]
      .filter(Boolean).join(" ").trim();

  const email = pick(leadObj, ["email", "Email"]);
  const phone = pick(leadObj, ["phone", "phoneNumber", "phone_number", "mobile"]);
  const company = pick(leadObj, ["company", "organization", "org"]);
  const message = pick(leadObj, ["message", "notes", "note", "comment"]);

  const raw = body?.raw ?? leadObj?.raw ?? body;

  return {
    source,
    type,
    lead: { fullName: fullName || undefined, email: email || undefined, phone: phone || undefined, company: company || undefined, message: message || undefined, raw },
  };
}

/**
 * Dedupe fingerprint:
 *  - stable
 *  - privacy-aware (hash only)
 *  - uses strongest identifiers first
 */
export function computeFingerprint(input: {
  tenantId: string;
  source: string;
  type: string;
  lead: NormalizedLead;
}): string {
  const email = (input.lead.email || "").toLowerCase().trim();
  const phone = (input.lead.phone || "").replace(/\s+/g,"").trim();
  const name = (input.lead.fullName || "").toLowerCase().trim();

  // strongest: email, then phone, then name
  const id = email || phone || name || "anon";
  const payload = JSON.stringify({
    v: 1,
    tenantId: input.tenantId,
    source: input.source,
    type: input.type,
    id,
  });

  return crypto.createHash("sha1").update(payload).digest("hex");
}

export function evaluateRules(args: {
  tenantId: string;
  source: string;
  type: string;
  lead: NormalizedLead;
}): RulesResult {
  const flags: TicketFlag[] = [];
  const missingFields: string[] = [];

  const email = (args.lead.email || "").trim();
  const name = (args.lead.fullName || "").trim();
  const phone = (args.lead.phone || "").trim();

  if (!email) { flags.push("missing_email"); missingFields.push("email"); }
  if (!name)  { flags.push("missing_name"); missingFields.push("fullName"); }
  if (!email && !phone) { flags.push("missing_contact"); missingFields.push("email_or_phone"); }

  // Basic payload sanity
  const rawStr = (() => {
    try { return JSON.stringify(args.lead.raw ?? {}, null, 0); } catch { return ""; }
  })();
  if (rawStr && rawStr.length > 25000) flags.push("suspicious_payload");

  // Very low signal => needs_review
  if (!email && !phone && !name) flags.push("low_signal");

  let status: TicketStatus = "new";
  if (flags.includes("missing_contact") || flags.includes("low_signal") || flags.includes("suspicious_payload")) {
    status = "needs_review";
  } else {
    status = "ready";
  }

  const fingerprint = computeFingerprint({ tenantId: args.tenantId, source: args.source, type: args.type, lead: args.lead });

  const title = (args.type === "lead" ? "Lead intake" : args.type) + (args.source ? ` (${args.source})` : "");

  return { status, flags, missingFields, title, fingerprint };
}
