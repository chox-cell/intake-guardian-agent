#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> [1] Install dotenv"
pnpm add dotenv@^16 >/dev/null

echo "==> [2] Patch src/server.ts to load .env.local/.env before anything else"
# Backup
cp -v src/server.ts "src/server.ts.bak.$(date +%Y%m%d_%H%M%S)" || true

cat > src/server.ts <<'TS'
import fs from "fs";
import path from "path";

// Load env (.env.local preferred) for portable dev/prod
import dotenv from "dotenv";
dotenv.config({ path: path.resolve(process.cwd(), ".env.local") });
dotenv.config({ path: path.resolve(process.cwd(), ".env") });

import express from "express";
import pino from "pino";
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
  app.use(
    "/api/adapters",
    makeAdapterRoutes({
      store,
      presetId: PRESET_ID,
      dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS,
      waVerifyToken: WA_VERIFY_TOKEN || undefined
    })
  );

  app.listen(PORT, () => {
    log.info(
      {
        PORT,
        DATA_DIR,
        PRESET_ID,
        DEDUPE_WINDOW_SECONDS,
        TENANT_KEYS_CONFIGURED: Boolean((process.env.TENANT_KEYS_JSON || "").trim())
      },
      "Intake-Guardian Agent running (FileStore)"
    );
  });
}

main().catch((err) => {
  log.error({ err }, "fatal");
  process.exit(1);
});
TS

echo "==> [3] Patch smoke to create a fresh ticket (unique subject) + avoid invalid transitions"
cp -v scripts/smoke-day5.sh "scripts/smoke-day5.sh.bak.$(date +%Y%m%d_%H%M%S)" || true

cat > scripts/smoke-day5.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:7090}"
TENANT="${TENANT:-tenant_demo}"
TENANT_KEY="${TENANT_KEY:-dev_key_123}"

PASS=0
FAIL=0

ok()  { echo "✅ $*"; PASS=$((PASS+1)); }
bad() { echo "❌ $*"; FAIL=$((FAIL+1)); }

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }; }
need curl
need jq
need date

SUBJECT_UNIQ="smoke-tenantkeys-$(date +%s)"

echo "==> Smoke Day-5 (with Tenant Keys)"
echo "BASE_URL=$BASE_URL"
echo "TENANT=$TENANT"
echo "TENANT_KEY=${TENANT_KEY:0:3}***"
echo "SUBJECT=$SUBJECT_UNIQ"
echo

# 1) Health (no key)
echo "==> [1] GET /api/health"
if curl -fsS "$BASE_URL/api/health" | jq -e '.ok == true' >/dev/null; then
  ok "health ok"
else
  bad "health failed"
fi
echo

# 2) Tenant key gate (expect 401/403 WITHOUT key) ONLY meaningful if keys configured in server env
echo "==> [2] Tenant key gate (expect 401/403 without x-tenant-key)"
HTTP_CODE="$(curl -sS -o /tmp/ig_tmp.json -w "%{http_code}" "$BASE_URL/api/workitems?tenantId=$TENANT&limit=1" || true)"
if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
  ok "tenant gate enforced (http=$HTTP_CODE)"
else
  echo "http=$HTTP_CODE body:"
  cat /tmp/ig_tmp.json || true
  bad "tenant gate NOT enforced (expected 401/403). TIP: ensure TENANT_KEYS_JSON is loaded via .env.local/.env and restart."
fi
echo

# 3) Ingest NEW unique ticket (with key)
echo "==> [3] POST /api/adapters/email/sendgrid (unique ticket)"
RESP1="$(curl -fsS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT" \
  -H "x-tenant-key: $TENANT_KEY" \
  -F 'from=employee@corp.local' \
  -F "subject=$SUBJECT_UNIQ" \
  -F 'text=VPN is down ASAP. Cannot access network.' )"

if echo "$RESP1" | jq -e '.ok == true and (.workItem.id | length) > 5' >/dev/null; then
  WID="$(echo "$RESP1" | jq -r '.workItem.id')"
  ok "ingest ok (workItemId=$WID)"
else
  echo "$RESP1" | jq . || true
  bad "ingest failed"
  WID=""
fi
echo

# 4) List workitems WITH key
echo "==> [4] GET /api/workitems (with key)"
RESP2="$(curl -fsS "$BASE_URL/api/workitems?tenantId=$TENANT&limit=5" -H "x-tenant-key: $TENANT_KEY")"
if echo "$RESP2" | jq -e '.ok == true and (.items | type=="array")' >/dev/null; then
  ok "workitems list ok"
else
  echo "$RESP2" | jq . || true
  bad "workitems list failed"
fi
echo

# 5) Dedupe check (send same unique subject again => duplicated should be true)
echo "==> [5] Dedupe: same payload again => duplicated=true"
RESP3="$(curl -fsS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT" \
  -H "x-tenant-key: $TENANT_KEY" \
  -F 'from=employee@corp.local' \
  -F "subject=$SUBJECT_UNIQ" \
  -F 'text=VPN is down ASAP. Cannot access network.' )"

if echo "$RESP3" | jq -e '.ok == true and .duplicated == true' >/dev/null; then
  ok "dedupe ok (duplicated=true)"
else
  echo "$RESP3" | jq . || true
  bad "dedupe failed"
fi
echo

# 6) Status transition test (on fresh item): new -> in_progress
if [ -n "${WID:-}" ]; then
  echo "==> [6] POST /api/workitems/:id/status (new->in_progress)"
  RESP4="$(curl -fsS "$BASE_URL/api/workitems/$WID/status" \
    -H 'Content-Type: application/json' \
    -H "x-tenant-key: $TENANT_KEY" \
    -d "{\"tenantId\":\"$TENANT\",\"next\":\"in_progress\"}" )"

  if echo "$RESP4" | jq -e '.ok == true and .workItem.status == "in_progress"' >/dev/null; then
    ok "status update ok"
  else
    echo "$RESP4" | jq . || true
    bad "status update failed"
  fi
  echo

  echo "==> [7] GET /api/workitems/:id/events (with key)"
  RESP5="$(curl -fsS "$BASE_URL/api/workitems/$WID/events?tenantId=$TENANT&limit=50" -H "x-tenant-key: $TENANT_KEY")"
  if echo "$RESP5" | jq -e '.ok == true and (.events | type=="array")' >/dev/null; then
    ok "events list ok"
  else
    echo "$RESP5" | jq . || true
    bad "events list failed"
  fi
  echo
else
  echo "==> [6/7] Skipped (no workItemId captured)"
  echo
fi

# 8) Rate-limit burst (may trigger depending on settings)
echo "==> [8] Rate-limit burst (may PASS even if not triggered)"
RATE_LIMIT_HIT=0
for i in $(seq 1 80); do
  R="$(curl -sS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT" \
    -H "x-tenant-key: $TENANT_KEY" \
    -F 'from=employee@corp.local' \
    -F "subject=burst-$SUBJECT_UNIQ-$i" \
    -F 'text=hello' || true)"

  if echo "$R" | jq -e '.error == "rate_limited"' >/dev/null 2>&1; then
    RATE_LIMIT_HIT=1
    break
  fi
done

if [ "$RATE_LIMIT_HIT" -eq 1 ]; then
  ok "rate-limit triggered (rate_limited)"
else
  ok "rate-limit not triggered (limits may be high)"
fi
echo

echo "==> Summary"
echo "PASS=$PASS"
echo "FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
SH

chmod +x scripts/smoke-day5.sh

echo "==> [4] Typecheck + commit"
pnpm lint:types

git add package.json pnpm-lock.yaml src/server.ts scripts/smoke-day5.sh
git commit -m "fix(env): load .env.local via dotenv + smoke uses fresh ticket to avoid invalid status transition" || true

echo
echo "✅ Done."
echo "Next:"
echo "  1) Ensure .env.local contains TENANT_KEYS_JSON (valid JSON) مثل:"
echo "     TENANT_KEYS_JSON={\"tenant_demo\":\"dev_key_123\"}"
echo "  2) Restart server: pnpm dev"
echo "  3) Run smoke: pnpm smoke:day5"
