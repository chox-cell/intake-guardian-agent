#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
BK="__bak_phase38b_${STAMP}"
mkdir -p "$BK"

echo "==> Phase38b OneShot (fix DecisionStore export) @ $ROOT"
cp -v src/lib/decision/decision_store.ts "$BK/" 2>/dev/null || true
echo "✅ backup -> $BK"

mkdir -p src/lib/decision

cat > src/lib/decision/decision_store.ts <<'TS'
import fs from "node:fs/promises";
import path from "node:path";

export type DecisionRecord = {
  id: string;
  tenantId: string;
  createdAt: string;
  title?: string;
  tier?: "GREEN" | "AMBER" | "RED" | "PURPLE" | string;
  score?: number;
  reason?: string;
  actions?: string[];
  signals?: Record<string, any>;
  evidence?: {
    zipPath?: string;
    csvPath?: string;
    hash?: string;
  };
  raw?: any;
};

function dataDir() {
  return process.env.DATA_DIR || "./data";
}

function ensureTenantId(tenantId: string) {
  const t = String(tenantId || "").trim();
  if (!t) throw new Error("missing tenantId");
  return t;
}

function decisionsFile(tenantId: string) {
  const t = ensureTenantId(tenantId);
  return path.join(process.cwd(), dataDir(), "tenants", t, "decisions.jsonl");
}

async function readJsonlSafe(file: string): Promise<any[]> {
  try {
    const raw = await fs.readFile(file, "utf8");
    const lines = raw.split("\n").map((l) => l.trim()).filter(Boolean);
    const out: any[] = [];
    for (const l of lines) {
      try { out.push(JSON.parse(l)); } catch {}
    }
    return out;
  } catch {
    return [];
  }
}

function normalizeRow(r: any, tenantId: string, idx: number): DecisionRecord {
  const id = String(r.id || r.decisionId || r.runId || `${idx}`);
  const createdAt = String(r.createdAt || r.ts || r.time || new Date().toISOString());
  const tier = r.tier || r.status?.tier || r.decision?.tier;
  const score = Number(r.score ?? r.status?.score ?? r.decision?.score ?? 0);
  const reason = r.reason || r.decision?.reason || r.status?.reason || "";
  const actions = Array.isArray(r.actions)
    ? r.actions
    : (Array.isArray(r.decision?.actions) ? r.decision.actions : []);
  const signals = r.signals || r.decision?.signals || r.inputs || {};
  const title = r.title || r.decision?.title || r.subject || "Decision";
  const evidence = r.evidence || r.decision?.evidence || {};

  return {
    id,
    tenantId,
    createdAt,
    title,
    tier,
    score,
    reason,
    actions,
    signals,
    evidence,
    raw: r,
  };
}

export async function listDecisions(tenantId: string, limit = 25): Promise<DecisionRecord[]> {
  const file = decisionsFile(tenantId);
  const rows = await readJsonlSafe(file);

  const mapped = rows
    .map((r, idx) => normalizeRow(r, tenantId, idx))
    .sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1))
    .slice(0, limit);

  return mapped;
}

export async function appendDecision(tenantId: string, rec: Partial<DecisionRecord> & { raw?: any }) {
  const t = ensureTenantId(tenantId);
  const file = decisionsFile(t);
  const dir = path.dirname(file);
  await fs.mkdir(dir, { recursive: true });

  const now = new Date().toISOString();
  const row = {
    id: rec.id || `dec_${Date.now()}`,
    tenantId: t,
    createdAt: rec.createdAt || now,
    title: rec.title,
    tier: rec.tier,
    score: rec.score,
    reason: rec.reason,
    actions: rec.actions,
    signals: rec.signals,
    evidence: rec.evidence,
    raw: rec.raw ?? rec,
  };

  await fs.appendFile(file, JSON.stringify(row) + "\n", "utf8");
  return row;
}

/**
 * ✅ Backward-compatible class expected by older UI/API routes.
 * Some files import: { DecisionStore } from "../lib/decision/decision_store.js"
 */
export class DecisionStore {
  tenantId: string;

  constructor(tenantId: string) {
    this.tenantId = ensureTenantId(tenantId);
  }

  async list(limit = 25) {
    return listDecisions(this.tenantId, limit);
  }

  async add(rec: Partial<DecisionRecord> & { raw?: any }) {
    return appendDecision(this.tenantId, rec);
  }

  filePath() {
    return decisionsFile(this.tenantId);
  }
}
TS

echo "✅ wrote src/lib/decision/decision_store.ts (adds export DecisionStore)"

echo "==> quick check (exports exist)"
node - <<'NODE'
const fs = require('fs');
const s = fs.readFileSync('src/lib/decision/decision_store.ts','utf8');
if (!s.includes('export class DecisionStore')) process.exit(1);
console.log("OK: DecisionStore export present");
NODE

echo
echo "✅ Phase38b installed."
echo "Now run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
