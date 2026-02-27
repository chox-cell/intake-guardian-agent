#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENVF="${ENVF:-$ROOT/.env.local}"
DATA_DIR="${DATA_DIR:-./data}"
KEYS="$DATA_DIR/tenant_keys.json"

TENANT_ID="${TENANT_ID:-tenant_1766927347649_12ef20a5147c}"

if [ ! -f "$KEYS" ]; then
  echo "FAIL: missing $KEYS"
  exit 1
fi

# Read key (no printing)
KEY="$(node - <<'NODE'
const fs = require("fs");
const KEYS = process.env.KEYS;
const TENANT_ID = process.env.TENANT_ID;
const j = JSON.parse(fs.readFileSync(KEYS,"utf8"));
const t = j.tenants?.[TENANT_ID];
if (!t || !t.tenantKey) process.exit(2);
process.stdout.write(String(t.tenantKey));
NODE
KEYS="$KEYS" TENANT_ID="$TENANT_ID")" || {
  echo "FAIL: could not resolve tenantKey for TENANT_ID=$TENANT_ID from $KEYS"
  exit 1
}

# Ensure env file exists
touch "$ENVF"

# Patch .env.local safely via Node (handles quotes, keeps other lines)
node - <<'NODE'
const fs = require("fs");

const envPath = process.env.ENVF;
const tenantId = process.env.TENANT_ID;
const tenantKey = process.env.KEY;

let s = fs.readFileSync(envPath, "utf8").replace(/\r\n/g, "\n");
let lines = s.split("\n").filter(Boolean);

function upsert(k, v) {
  const i = lines.findIndex(line => line.startsWith(k + "="));
  if (i >= 0) lines[i] = `${k}=${v}`;
  else lines.push(`${k}=${v}`);
}

// IMPORTANT: store TENANT_KEYS_JSON as a plain JSON string (single layer), no extra wrapping.
const map = JSON.stringify({ [tenantId]: tenantKey });

upsert("TENANT_ID", tenantId);
upsert("TENANT_KEY_DEMO", tenantKey);
upsert("TENANT_KEYS_JSON", `'${map}'`);
upsert("TENANT_KEYS", `'${map}'`);

// keep file stable
lines = lines.filter((v,i,a)=>a.indexOf(v)===i);

fs.writeFileSync(envPath, lines.join("\n") + "\n", "utf8");

// No secrets printed
console.log("OK: synced .env.local from data (no secrets)");
console.log(" - TENANT_ID set");
console.log(" - TENANT_KEY_DEMO length =", String(tenantKey).length);
console.log(" - TENANT_KEYS_JSON has tenantId =", tenantId);
NODE

echo "OK: done. Now reload env + run probe/e2e:"
echo "  set -a; source ./.env.local; set +a"
echo "  ./scripts/probe-phase52.sh"
echo "  ./scripts/e2e-phase48.sh"
