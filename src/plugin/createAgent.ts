import { z } from "zod";
import pino from "pino";
import { Store } from "../store/store.js";
import { buildWorkItem } from "../core/engine.js";
import { makeAudit } from "../audit/audit.js";
import { canTransition } from "../core/transitions.js";
import { InboundEvent } from "../types/contracts.js";

const InboundSchema = z.object({
  tenantId: z.string().min(1),
  source: z.enum(["email","whatsapp","form","api"]),
  sender: z.string().min(1),
  subject: z.string().optional(),
  body: z.string().min(1),
  meta: z.record(z.unknown()).optional(),
  receivedAt: z.string().min(1)
});

export function createAgent(args: {
  store: Store;
  presetId: string;
  dedupeWindowSeconds: number;
  logger?: any;
}) {
  const log = args.logger ?? pino({ level: process.env.LOG_LEVEL || "info" });

  async function intake(raw: unknown) {
    const ev = InboundSchema.parse(raw) as InboundEvent;

    const candidate = buildWorkItem(ev, args.presetId);

    // dedupe gate
    const existing = await args.store.findByFingerprint(ev.tenantId, candidate.fingerprint, args.dedupeWindowSeconds);
    if (existing) {
      await args.store.appendAudit(makeAudit({
        tenantId: ev.tenantId,
        workItemId: existing.id,
        type: "duplicate_received",
        payload: { source: ev.source, sender: ev.sender }
      }));
      log.info({ workItemId: existing.id }, "dedupe: duplicate_received");
      return { ok: true, duplicated: true, workItem: existing };
    }

    await args.store.createWorkItem(candidate);
    await args.store.appendAudit(makeAudit({
      tenantId: ev.tenantId,
      workItemId: candidate.id,
      type: "created",
      payload: { source: ev.source, sender: ev.sender, presetId: args.presetId }
    }));

    log.info({ workItemId: candidate.id }, "workitem: created");
    return { ok: true, duplicated: false, workItem: candidate };
  }

  async function updateStatus(tenantId: string, id: string, next: any) {
    const WorkStatus = z.enum(["new","triage","in_progress","waiting","resolved","closed"]);
    const nextStatus = WorkStatus.parse(next);

    const current = await args.store.getWorkItem(tenantId, id);
    if (!current) return { ok: false, error: "not_found" };

    if (!canTransition(current.status, nextStatus)) {
      return { ok: false, error: "invalid_transition", from: current.status, to: nextStatus };
    }

    await args.store.updateStatus(tenantId, id, nextStatus);
    await args.store.appendAudit(makeAudit({
      tenantId,
      workItemId: id,
      type: "status_changed",
      payload: { from: current.status, to: nextStatus }
    }));

    const updated = await args.store.getWorkItem(tenantId, id);
    return { ok: true, workItem: updated };
  }

  async function assignOwner(tenantId: string, id: string, ownerId: any) {
    const owner = ownerId === null ? null : z.string().min(1).parse(ownerId);
    const current = await args.store.getWorkItem(tenantId, id);
    if (!current) return { ok: false, error: "not_found" };

    await args.store.assignOwner(tenantId, id, owner);
    await args.store.appendAudit(makeAudit({
      tenantId,
      workItemId: id,
      type: "owner_assigned",
      payload: { from: current.ownerId ?? null, to: owner }
    }));

    const updated = await args.store.getWorkItem(tenantId, id);
    return { ok: true, workItem: updated };
  }

  return { intake, updateStatus, assignOwner };
}
