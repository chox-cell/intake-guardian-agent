#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${TS}_tenants_ssot_v1"
mkdir -p "$BAK"

echo "==> One-shot: Tenants SSOT + UI auth (no more 401 mismatch)"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"

# Backup target files if exist
for f in src/lib/tenant_registry.ts src/ui/routes.ts; do
  if [ -f "$f" ]; then
    mkdir -p "$BAK/$(dirname "$f")"
    cp -a "$f" "$BAK/$f"
  fi
done

# 1) Overwrite tenant_registry.ts with SSOT + legacy merge implementation
mkdir -p src/lib
cat > src/lib/tenant_registry.ts <<'EOF'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

/**
 * Tenants Registry — SSOT v1
 * - Canonical file: <DATA_DIR>/tenant_registry.v1.json
 * - Legacy merge: reads other known tenant files and normalizes into canonical.
 * - Never logs tenantKey.
 */

export type TenantRecord = {
  tenantId: string;
  tenantKey: string;
  createdAtUtc?: string;
  updatedAtUtc?: string;
  notes?: string;
};

type RegistryDoc = {
  version?: number;
  tenants: TenantRecord[];
  updatedAtUtc?: string;
};

const CANON_FILE = "tenant_registry.v1.json";

// Legacy files we’ve seen in the project history / data dir
const LEGACY_FILES = [
  "tenant_registry.json",
  "tenant_registry.v1.json", // also include in merge; we will re-write canonical if needed
  "tenants.json",
  "tenant_keys.json",
  "admin.tenants.json",
  path.join("tenants", "registry.json"),
  path.join("tenants", "tenants.json"),
];

function nowUtc() {
  return new Date().toISOString();
}

function safeReadJson(fileAbs: string): any | null {
  try {
    if (!fs.existsSync(fileAbs)) return null;
    const raw = fs.readFileSync(fileAbs, "utf8");
    if (!raw.trim()) return null;
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function normalizeTenantsDoc(doc: any): TenantRecord[] {
  if (!doc) return [];

  // If doc = { tenants: [...] }
  if (Array.isArray(doc.tenants)) return doc.tenants.map(normalizeTenant).filter(Boolean) as TenantRecord[];

  // If doc = [ ... ]
  if (Array.isArray(doc)) return doc.map(normalizeTenant).filter(Boolean) as TenantRecord[];

  // If doc = { <tenantId>: { tenantKey: ... } }
  if (typeof doc === "object") {
    const out: TenantRecord[] = [];
    for (const [k, v] of Object.entries(doc)) {
      if (typeof v === "object" && v) {
        out.push(
          normalizeTenant({
            tenantId: (v as any).tenantId || k,
            tenantKey: (v as any).tenantKey || (v as any).key || (v as any).k,
            notes: (v as any).notes,
            createdAtUtc: (v as any).createdAtUtc,
            updatedAtUtc: (v as any).updatedAtUtc,
          }) as any
        );
      }
    }
    return out.filter(Boolean) as TenantRecord[];
  }

  return [];
}

function normalizeTenant(t: any): TenantRecord | null {
  if (!t) return null;
  const tenantId = String(t.tenantId || "").trim();
  const tenantKey = String(t.tenantKey || t.key || t.k || "").trim();
  if (!tenantId || !tenantKey) return null;

  return {
    tenantId,
    tenantKey,
    notes: t.notes ? String(t.notes) : undefined,
    createdAtUtc: t.createdAtUtc ? String(t.createdAtUtc) : undefined,
    updatedAtUtc: t.updatedAtUtc ? String(t.updatedAtUtc) : undefined,
  };
}

function ensureDir(dirAbs: string) {
  fs.mkdirSync(dirAbs, { recursive: true });
}

function canonicalPath(dataDirAbs: string) {
  return path.join(dataDirAbs, CANON_FILE);
}

function constantTimeEq(a: string, b: string) {
  try {
    const aa = Buffer.from(String(a));
    const bb = Buffer.from(String(b));
    if (aa.length !== bb.length) return false;
    return crypto.timingSafeEqual(aa, bb);
  } catch {
    return false;
  }
}

function loadRegistryDoc(dataDirAbs: string): RegistryDoc {
  ensureDir(dataDirAbs);

  const canonAbs = canonicalPath(dataDirAbs);
  const canonDoc = safeReadJson(canonAbs);
  const canonTenants = normalizeTenantsDoc(canonDoc);

  // Merge legacy
  const merged: Record<string, TenantRecord> = {};
  for (const t of canonTenants) merged[t.tenantId] = t;

  for (const rel of LEGACY_FILES) {
    const abs = path.join(dataDirAbs, rel);
    const doc = safeReadJson(abs);
    const list = normalizeTenantsDoc(doc);
    for (const t of list) {
      const prev = merged[t.tenantId];
      if (!prev) {
        merged[t.tenantId] = t;
      } else {
        // keep newest timestamps if present
        merged[t.tenantId] = {
          ...prev,
          ...t,
          createdAtUtc: prev.createdAtUtc || t.createdAtUtc,
          updatedAtUtc: t.updatedAtUtc || prev.updatedAtUtc,
          tenantKey: t.tenantKey || prev.tenantKey,
        };
      }
    }
  }

  const tenants = Object.values(merged)
    .filter((t) => t.tenantId && t.tenantKey)
    .sort((a, b) => String(a.createdAtUtc || "").localeCompare(String(b.createdAtUtc || "")));

  return {
    version: 1,
    tenants,
    updatedAtUtc: nowUtc(),
  };
}

function writeCanonicalIfChanged(dataDirAbs: string, doc: RegistryDoc) {
  const canonAbs = canonicalPath(dataDirAbs);
  const prev = safeReadJson(canonAbs);
  const prevList = normalizeTenantsDoc(prev);
  const nextList = doc.tenants;

  // cheap equality: count + ids+keys
  const prevSig = prevList.map((t) => `${t.tenantId}:${t.tenantKey}`).join("|");
  const nextSig = nextList.map((t) => `${t.tenantId}:${t.tenantKey}`).join("|");
  if (prevSig === nextSig) return;

  fs.writeFileSync(canonAbs, JSON.stringify(doc, null, 2) + "\n", "utf8");
}

function randKey32() {
  // url-safe
  return crypto.randomBytes(24).toString("base64url");
}

export function listTenants(dataDirAbs?: string): TenantRecord[] {
  const dir = path.resolve(dataDirAbs || process.env.DATA_DIR || "./data");
  const doc = loadRegistryDoc(dir);
  writeCanonicalIfChanged(dir, doc);
  return doc.tenants;
}

export function getTenant(tenantId: string, dataDirAbs?: string): TenantRecord | null {
  const dir = path.resolve(dataDirAbs || process.env.DATA_DIR || "./data");
  const doc = loadRegistryDoc(dir);
  writeCanonicalIfChanged(dir, doc);
  const t = doc.tenants.find((x) => x.tenantId === tenantId);
  return t || null;
}

export function upsertTenantRecord(rec: TenantRecord, dataDirAbs?: string) {
  const dir = path.resolve(dataDirAbs || process.env.DATA_DIR || "./data");
  const doc = loadRegistryDoc(dir);

  const clean: TenantRecord = {
    tenantId: String(rec.tenantId || "").trim(),
    tenantKey: String(rec.tenantKey || "").trim(),
    notes: rec.notes ? String(rec.notes) : undefined,
    createdAtUtc: rec.createdAtUtc || nowUtc(),
    updatedAtUtc: rec.updatedAtUtc || nowUtc(),
  };

  const idx = doc.tenants.findIndex((t) => t.tenantId === clean.tenantId);
  if (idx >= 0) {
    doc.tenants[idx] = {
      ...doc.tenants[idx],
      ...clean,
      createdAtUtc: doc.tenants[idx].createdAtUtc || clean.createdAtUtc,
      updatedAtUtc: nowUtc(),
    };
  } else {
    doc.tenants.push(clean);
  }

  doc.updatedAtUtc = nowUtc();
  writeCanonicalIfChanged(dir, doc);
}

export function createTenant(dataDirAbs?: string, notes?: string): TenantRecord {
  const dir = path.resolve(dataDirAbs || process.env.DATA_DIR || "./data");
  const tenantId = `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
  const tenantKey = randKey32();

  const rec: TenantRecord = {
    tenantId,
    tenantKey,
    notes: notes ? String(notes) : undefined,
    createdAtUtc: nowUtc(),
    updatedAtUtc: nowUtc(),
  };

  upsertTenantRecord(rec, dir);
  return rec;
}

export function rotateTenantKey(tenantId: string, dataDirAbs?: string): TenantRecord | null {
  const dir = path.resolve(dataDirAbs || process.env.DATA_DIR || "./data");
  const t = getTenant(tenantId, dir);
  if (!t) return null;
  const next: TenantRecord = { ...t, tenantKey: randKey32(), updatedAtUtc: nowUtc() };
  upsertTenantRecord(next, dir);
  return next;
}

/**
 * verifyTenantKeyLocal(tenantId, tenantKey, dataDirAbs?)
 * IMPORTANT: This is the single gate used by UI pages.
 */
export function verifyTenantKeyLocal(tenantId: string, tenantKey: string, dataDirAbs?: string): boolean {
  if (!tenantId || !tenantKey) return false;
  const dir = path.resolve(dataDirAbs || process.env.DATA_DIR || "./data");
  const t = getTenant(String(tenantId), dir);
  if (!t) return false;
  return constantTimeEq(String(t.tenantKey), String(tenantKey));
}

/**
 * Demo tenant helper — used by older routes/tests.
 */
export function getOrCreateDemoTenant(dataDirAbs?: string): TenantRecord {
  const dir = path.resolve(dataDirAbs || process.env.DATA_DIR || "./data");
  const existing = getTenant("tenant_demo", dir);
  if (existing) return existing;

  const rec: TenantRecord = {
    tenantId: "tenant_demo",
    tenantKey: randKey32(),
    notes: "Demo tenant (local)",
    createdAtUtc: nowUtc(),
    updatedAtUtc: nowUtc(),
  };

  upsertTenantRecord(rec, dir);
  return rec;
}
EOF

echo "OK: wrote src/lib/tenant_registry.ts (SSOT + legacy merge)"

# 2) Patch UI routes.ts to always pass DATA_DIR to verifyTenantKeyLocal()
node <<'NODE'
const fs = require("fs");
const path = require("path");

const file = path.join(process.cwd(), "src/ui/routes.ts");
if (!fs.existsSync(file)) {
  console.error("FAIL: src/ui/routes.ts not found");
  process.exit(1);
}

let s = fs.readFileSync(file, "utf8");

// Ensure we import path if needed (routes.ts usually uses path already; keep safe)
if (!s.match(/from ["']node:path["']/) && !s.match(/from ["']path["']/)) {
  // Insert after first import line
  const lines = s.split("\n");
  let idx = lines.findIndex(l => l.startsWith("import "));
  if (idx === -1) idx = 0;
  lines.splice(idx + 1, 0, `import path from "node:path";`);
  s = lines.join("\n");
}

// Replace verifyTenantKeyLocal(...) call to include resolved DATA_DIR
// We only change the call inside mustAuth() style blocks.
s = s.replace(
  /verifyTenantKeyLocal\(\s*tenantId\s*,\s*tenantKey\s*\)/g,
  'verifyTenantKeyLocal(tenantId, tenantKey, path.resolve(process.env.DATA_DIR || "./data"))'
);

// Also replace any variants that pass only 2 args with variables
s = s.replace(
  /verifyTenantKeyLocal\(\s*([A-Za-z0-9_.$]+)\s*,\s*([A-Za-z0-9_.$]+)\s*\)/g,
  'verifyTenantKeyLocal($1, $2, path.resolve(process.env.DATA_DIR || "./data"))'
);

// Avoid double-inserting if it already has 3 args
s = s.replace(
  /verifyTenantKeyLocal\(\s*([^,]+)\s*,\s*([^,]+)\s*,\s*path\.resolve\([^)]+\)\s*,\s*path\.resolve\([^)]+\)\s*\)/g,
  'verifyTenantKeyLocal($1, $2, path.resolve(process.env.DATA_DIR || "./data"))'
);

fs.writeFileSync(file, s, "utf8");
console.log("OK: patched src/ui/routes.ts (verify uses same DATA_DIR)");
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ Tenants SSOT applied"
echo "Backup: $BAK"
echo
echo "NEXT (run exactly):"
echo "  kill -9 \$(lsof -t -iTCP:7090 -sTCP:LISTEN) 2>/dev/null || true"
echo "  ADMIN_KEY='dev_admin_key_123' bash scripts/dev_7090.sh"
echo
echo "TEST (must be 200):"
echo "  curl -sS -X POST http://127.0.0.1:7090/api/admin/provision \\"
echo "    -H 'content-type: application/json' \\"
echo "    -H 'x-admin-key: dev_admin_key_123' \\"
echo "    -d '{\"workspaceName\":\"salam\",\"agencyEmail\":\"test+agency@local.dev\"}' | jq ."
echo
echo "  # then open the tickets link from the response (must NOT be 401)"
