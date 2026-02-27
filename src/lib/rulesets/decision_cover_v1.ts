export const RULESET_ID = "decision_cover.v1";
export const RULESET_VERSION = "1.0.0";

export function runDecisionCoverV1(input: {
  ticketPayload?: any;
  notes?: string;
  context?: any;
}): { ok: true; confidence: number; reasons: string[] } {
  const reasons: string[] = [];
  let confidence = 60;

  const hasTicket = Boolean(input.ticketPayload);
  const hasNotes = Boolean((input.notes || "").trim());

  if (hasTicket) { confidence += 20; reasons.push("ticket_snapshot_present"); }
  if (hasNotes) { confidence += 15; reasons.push("notes_present"); }
  if (!hasTicket && !hasNotes) { reasons.push("low_evidence"); confidence -= 10; }

  if (confidence > 95) confidence = 95;
  if (confidence < 10) confidence = 10;

  return { ok: true, confidence, reasons };
}
