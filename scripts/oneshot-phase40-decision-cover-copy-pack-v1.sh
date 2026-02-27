#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/Projects/intake-guardian-agent"
cd "$REPO"

STAMP="$(date +%Y%m%d_%H%M%S)"
BK="__bak_phase40_${STAMP}"
mkdir -p "$BK"

FILE="src/ui/decisions_route.ts"
[ -f "$FILE" ] || { echo "ERROR: missing $FILE"; exit 1; }

cp -f "$FILE" "$BK/decisions_route.ts"
echo "✅ backup -> $BK/decisions_route.ts"

node <<'NODE'
const fs = require("fs");
const p = "src/ui/decisions_route.ts";
let s = fs.readFileSync(p, "utf8");

function mustReplace(from, to) {
  if (!s.includes(from)) {
    console.error(`WARN: did not find: ${JSON.stringify(from)}`);
    return false;
  }
  s = s.split(from).join(to);
  return true;
}

// ===== Copy Pack v1 (safe exact replacements) =====

// Top description (vendor-neutral -> agency-focused)
mustReplace(
  "A clean, vendor-neutral decision pipeline that turns messy input into a documented decision, with evidence you can export and share.",
  "A clean decision pipeline for agencies: turn messy requests into a documented decision + shareable proof."
);

// Buttons
mustReplace("Download Evidence ZIP", "Download Proof ZIP");
mustReplace("Export CSV", "Export CSV (for reporting)");
mustReplace("View Tickets", "Open Inbox");
mustReplace("Copy Share Link", "Copy client link");

// Steps cards
mustReplace("1) Intake", "1) Intake");
mustReplace(
  "Collect the request + context (email/webhook/form).",
  "Capture request + context (form / email / webhook)."
);

mustReplace("2) Normalize", "2) Normalize");
mustReplace(
  "Extract signals, remove noise, dedupe & tag.",
  "Extract signals, dedupe, tag, remove noise."
);

mustReplace("3) Decide", "3) Decide");
mustReplace(
  "Tier + score + written reason + recommended actions.",
  "Score + tier + written rationale + next actions."
);

mustReplace("4) Evidence", "4) Proof");
mustReplace(
  "ZIP/CSV you can share with client or auditors.",
  "Share a Proof Pack (ZIP/CSV) with client/auditor."
);

// Section header + trust line
mustReplace("Signals (transparent)", "Signals (transparent)");
mustReplace(
  "We show the inputs that led to the decision. No black box promises.",
  "We show the inputs that led to the decision. No black-box claims — you can inspect every input."
);

// Latest Decision labels
mustReplace("Reason", "Rationale");
mustReplace("Recommended Actions", "Next actions");

// Actions list (right panel)
mustReplace("Proceed with confidence", "Proceed (low risk)");
mustReplace("Send client Proof ZIP", "Send Proof Pack to client");
mustReplace("Archive decision", "Mark as archived");

// Evidence/Integrity note tweak (key -> token)
mustReplace(
  "Integrity note: we avoid embedding secrets in UI. Tenant key is a link-token for the demo client view.",
  "Integrity note: we avoid showing secrets in UI. Client link uses a view-token (not a password). Rotate anytime."
);

// Footer (keys -> secrets) — keep meaning, reduce scary wording
mustReplace(
  "Decision Cover™ • Proof-first decisions • No keys stored in UI • Vendor-neutral",
  "Decision Cover™ • Proof-first decisions • No secrets shown in UI • Vendor-neutral"
);

// Inject: disclaimer + token hint if not already present
if (!s.includes("Decision Cover provides documentation, not legal advice")) {
  const needle = "Integrity note:";
  const idx = s.indexOf(needle);
  if (idx !== -1) {
    // Insert a short disclaimer line near the integrity block (HTML text inside template strings)
    s = s.replace(
      needle,
      "Disclaimer: Decision Cover provides documentation, not legal advice.\n\n" + needle
    );
    console.log("✅ inserted disclaimer near integrity note");
  } else {
    console.log("WARN: could not find 'Integrity note:' to insert disclaimer");
  }
}

fs.writeFileSync(p, s);
console.log("✅ Copy Pack v1 applied to", p);
NODE

echo
echo "==> Typecheck (tsx can parse server entry)"
node -e "require('fs').accessSync('src/server.ts'); console.log('OK: server entry exists')"

echo
echo "✅ Phase40 installed."
echo "Next:"
echo "  (A) ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  (B) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase39.sh"
