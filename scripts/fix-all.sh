#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> [1] Safety snapshot"
git status --porcelain || true

echo "==> [2] Remove native sqlite deps (ignore if missing)"
pnpm remove better-sqlite3 sqlite3 >/dev/null 2>&1 || true
pnpm remove -D @types/better-sqlite3 >/dev/null 2>&1 || true

echo "==> [3] Ensure multer v2 + types"
pnpm add multer@^2 >/dev/null 2>&1 || true
pnpm add -D @types/multer@^1.4.12 >/dev/null 2>&1 || true

echo "==> [4] Clean install"
rm -rf node_modules pnpm-lock.yaml
pnpm store prune >/dev/null 2>&1 || true
pnpm i

echo "==> [5] Write FileStore (portable JSONL)"
mkdir -p src/store
cat > src/store/file.ts <<'TS'
import fs from "fs";
import path from "path";
import { Store } from "./store.js";
import { AuditEvent, WorkItem, Status } from "../types/contracts.js";

type Index = {
  workitems: WorkItem[];
  workById: Map<string, WorkItem>;
  auditByWorkId: Map<string, AuditEvent[]>;
};

export class FileStore implements Store {
  private dir: string;
  private workPath: string;
  private auditPath: string;

  private idx: Index = {
    workitems: [],
    workById: new Map(),
    auditByWorkId: new Map()
  };

  constructor(dataDir: string) {
    this.dir = dataDir;
    this.workPath = path.join(this.dir, "workitems.jsonl");
    this.auditPath = path.join(this.dir, "audit.jsonl");
  }

  async init(): Promise<void> {
    fs.mkdirSync(this.dir, { recursive: true });
    if (!fs.existsSync(this.workPath)) fs.writeFileSync(this.workPath, "", "utf8");
    if (!fs.existsSync(this.auditPath)) fs.writeFileSync(this.auditPath, "", "utf8");
    this.loadWorkItems();
    this.loadAudit();
  }

  private loadWorkItems() {
    const lines = fs.readFileSync(this.workPath, "utf8").split("\n").filter(Boolean);
    for (const line of lines) {
      try {
        const wi = JSON.parse(line) as WorkItem;
        this.idx.workitems.push(wi);
        this.idx.workById.set(this.key(wi.tenantId, wi.id), wi);
      } catch {}
    }
    this.idx.workitems.sort((a, b) => (b.updatedAt || b.createdAt).localeCompare(a.updatedAt || a.createdAt));
  }

  private loadAudit() {
    const lines = fs.readFileSync(this.auditPath, "utf8").split("\n").filter(Boolean);
    for (const line of lines) {
      try {
        const ev = JSON.parse(line) as AuditEvent;
        const k = this.key(ev.tenantId, ev.workItemId);
        const arr = this.idx.auditByWorkId.get(k) ?? [];
        arr.push(ev);
        this.idx.auditByWorkId.set(k, arr);
      } catch {}
    }
  }

  private appendLine(filePath: string, obj: any) {
    fs.appendFileSync(filePath, JSON.stringify(obj) + "\n", "utf8");
  }

  private key(tenantId: string, id: string) {
    return `${tenantId}::${id}`;
  }

  async createWorkItem(item: WorkItem): Promise<void> {
    this.appendLine(this.workPath, item);
    this.idx.workitems.unshift(item);
    this.idx.workById.set(this.key(item.tenantId, item.id), item);
  }

  async getWorkItem(tenantId: string, id: string): Promise<WorkItem | null> {
    return this.idx.workById.get(this.key(tenantId, id)) ?? null;
  }

  async listWorkItems(
    tenantId: string,
    q: { status?: Status; limit?: number; offset?: number; search?: string }
  ): Promise<WorkItem[]> {
    const limit = Math.min(q.limit ?? 50, 200);
    const offset = q.offset ?? 0;
    const search = (q.search ?? "").toLowerCase().trim();

    const filtered = this.idx.workitems.filter((w) => {
      if (w.tenantId !== tenantId) return false;
      if (q.status && w.status !== q.status) return false;
      if (search) {
        const hay = `${w.normalizedBody} ${w.sender} ${w.subject ?? ""}`.toLowerCase();
        if (!hay.includes(search)) return false;
      }
      return true;
    });

    return filtered.slice(offset, offset + limit);
  }

  async findByFingerprint(tenantId: string, fingerprint: string, windowSeconds: number): Promise<WorkItem | null> {
    const sinceMs = Date.now() - windowSeconds * 1000;
    for (const w of this.idx.workitems) {
      if (w.tenantId !== tenantId) continue;
      if (w.fingerprint !== fingerprint) continue;
      const createdMs = Date.parse(w.createdAt);
      if (!Number.isFinite(createdMs)) continue;
      if (createdMs >= sinceMs) return w;
    }
    return null;
  }

  async updateStatus(tenantId: string, id: string, next: Status): Promise<void> {
    const k = this.key(tenantId, id);
    const cur = this.idx.workById.get(k);
    if (!cur) return;

    const updated: WorkItem = { ...cur, status: next, updatedAt: new Date().toISOString() };
    this.appendLine(this.workPath, updated);

    this.idx.workById.set(k, updated);
    this.idx.workitems = this.idx.workitems.map((w) => (w.tenantId === tenantId && w.id === id ? updated : w));
  }

  async assignOwner(tenantId: string, id: string, ownerId: string | null): Promise<void> {
    const k = this.key(tenantId, id);
    const cur = this.idx.workById.get(k);
    if (!cur) return;

    const updated: WorkItem = { ...cur, ownerId: ownerId ?? undefined, updatedAt: new Date().toISOString() };
    this.appendLine(this.workPath, updated);

    this.idx.workById.set(k, updated);
    this.idx.workitems = this.idx.workitems.map((w) => (w.tenantId === tenantId && w.id === id ? updated : w));
  }

  async appendAudit(ev: AuditEvent): Promise<void> {
    this.appendLine(this.auditPath, ev);
    const k = this.key(ev.tenantId, ev.workItemId);
    const arr = this.idx.auditByWorkId.get(k) ?? [];
    arr.push(ev);
    this.idx.auditByWorkId.set(k, arr);
  }

  async listAudit(tenantId: string, workItemId: string, limit: number = 200): Promise<AuditEvent[]> {
    const k = this.key(tenantId, workItemId);
    const arr = this.idx.auditByWorkId.get(k) ?? [];
    return arr.slice(Math.max(0, arr.length - Math.min(limit, 1000)));
  }
}
TS

echo "==> [6] Update src/server.ts to use FileStore"
cat > src/server.ts <<'TS'
import express from "express";
import pino from "pino";
import fs from "fs";
import path from "path";
import { makeRoutes } from "./api/routes.js";
import { makeAdapterRoutes } from "./api/adapters.js";
import { captureRawBody } from "./api/raw-body.js";
import { FileStore } from "./store/file.js";

const log = pino({ level: process.env.LOG_LEVEL || "info" });

const PORT = Number(process.env.PORT || 7090);
const DATA_DIR = process.env.DATA_DIR || "./data";
const PRESET_ID = process.env.PRESET_ID || "it_support.v1";
const DEDUPE_WINDOW_SECONDS = Number(process.env.DEDUPE_WINDOW_SECONDS || 86400);
const WA_VERIFY_TOKEN = process.env.WA_VERIFY_TOKEN || "";

fs.mkdirSync(DATA_DIR, { recursive: true });
const store = new FileStore(path.resolve(DATA_DIR));

async function main() {
  await store.init();

  const app = express();
  app.use(express.json({ limit: "512kb", verify: captureRawBody as any }));
  app.use(express.urlencoded({ extended: true, limit: "512kb", verify: captureRawBody as any }));

  app.use("/api", makeRoutes({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS }));
  app.use("/api/adapters", makeAdapterRoutes({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS, waVerifyToken: WA_VERIFY_TOKEN || undefined }));

  app.listen(PORT, () => {
    log.info({ PORT, DATA_DIR, PRESET_ID, DEDUPE_WINDOW_SECONDS }, "Intake-Guardian Agent running (FileStore)");
  });
}

main().catch((err) => {
  log.error({ err }, "fatal");
  process.exit(1);
});
TS

echo "==> [7] Fix exports/imports referencing sqlite store"
cat > src/index.ts <<'TS'
export { createAgent } from "./plugin/createAgent.js";
export { makeRoutes } from "./api/routes.js";
export { makeAdapterRoutes } from "./api/adapters.js";
export { FileStore } from "./store/file.js";
export type { InboundEvent, WorkItem, AuditEvent, Source, Status, Priority } from "./types/contracts.js";
TS

mkdir -p src/scripts
cat > src/scripts/db-init.ts <<'TS'
async function main() {
  console.log("db-init: no-op (FileStore).");
}
main().catch((e: unknown) => {
  console.error("db-init failed:", e);
  process.exit(1);
});
TS

echo "==> [8] Remove old sqlite store file (avoid accidental imports)"
rm -f src/store/sqlite.ts || true

echo "==> [9] Move *.bak.* files into .tmp_backups (no syntax tricks)"
mkdir -p .tmp_backups
find src -name "*.bak.*" -type f -maxdepth 6 -print0 2>/dev/null | while IFS= read -r -d '' f; do
  mv "$f" .tmp_backups/ || true
done

echo "==> [10] Typecheck"
pnpm lint:types

echo "==> [11] Git commit"
git add package.json pnpm-lock.yaml src/store/file.ts src/server.ts src/index.ts src/scripts/db-init.ts
git commit -m "fix(all): switch to FileStore JSONL, remove native sqlite, repair imports" || true

echo "==> [12] Run"
pnpm dev
