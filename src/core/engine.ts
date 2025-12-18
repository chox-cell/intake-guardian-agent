import { nanoid } from "nanoid";
import { InboundEvent, WorkItem } from "../types/contracts.js";
import { normalizeText } from "./normalize.js";
import { fingerprintOf } from "./dedupe.js";
import * as it from "../presets/it-support.v1.js";

export function buildWorkItem(ev: InboundEvent, presetId: string): WorkItem {
  if (presetId !== it.presetId) {
    throw new Error(`Unknown presetId: ${presetId}`);
  }

  const normalized = normalizeText(ev.body);
  const category = it.classifyCategory(normalized);
  const priority = it.classifyPriority(normalized, category);
  const slaSeconds = it.slaForPriority(priority);

  const now = new Date();
  const dueAt = new Date(now.getTime() + slaSeconds * 1000).toISOString();

  const fingerprint = fingerprintOf({
    tenantId: ev.tenantId,
    sender: ev.sender,
    normalizedBody: normalized,
    presetId
  });

  return {
    id: nanoid(),
    tenantId: ev.tenantId,
    source: ev.source,
    sender: ev.sender,
    subject: ev.subject,
    rawBody: ev.body,
    normalizedBody: normalized,
    category,
    priority,
    status: priority === "critical" ? "triage" : "new",
    ownerId: undefined,
    slaSeconds,
    dueAt,
    tags: [],
    fingerprint,
    presetId,
    createdAt: now.toISOString(),
    updatedAt: now.toISOString()
  };
}
