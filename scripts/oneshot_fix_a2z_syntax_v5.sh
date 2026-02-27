#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK/scripts"

cp -v scripts/client_experience_a2z.sh "$BAK/scripts/client_experience_a2z.sh.bak"

echo "==> Patch: replace verify+parse block with Node-only safe block"

perl -0777 -pi -e '
# Replace the whole Step 3/4 section robustly.
# We look for the header "==> 3) Verify" and replace until just before "==> 5) Send demo leads".
my $replacement = <<'"'"'BLOCK'"'"';
echo
echo "==> 3) Verify (follow redirects; capture final URL)"

# Follow redirects and capture the final URL (welcome)
WELCOME="$(curl -sS -L -o /dev/null -w "%{url_effective}" "$VERIFY_URL" || true)"
if [ -z "$WELCOME" ] || [[ "$WELCOME" != *"/ui/welcome"* ]]; then
  echo "FAIL: verify did not end at /ui/welcome" >&2
  echo "Got: $WELCOME" >&2
  exit 1
fi

echo "OK: welcome => $WELCOME"

TENANT_ID="$(node -e '"'"'const u=new URL(process.argv[1]); console.log(u.searchParams.get("tenantId")||"");'"'"' "$WELCOME")"
K="$(node -e '"'"'const u=new URL(process.argv[1]); console.log(u.searchParams.get("k")||"");'"'"' "$WELCOME")"

if [ -z "$TENANT_ID" ] || [ -z "$K" ]; then
  echo "FAIL: could not extract tenantId/k from welcome URL" >&2
  echo "WELCOME: $WELCOME" >&2
  exit 1
fi

echo "OK: tenantId extracted"
echo "OK: k extracted (hidden)"
echo "Welcome URL: $WELCOME"

echo
echo "==> 4) (Manual) Open Welcome UI in browser"
echo "$WELCOME"
BLOCK

$_ =~ s/echo\s*\necho\s*"==>\s*3\)\s*Verify[\s\S]*?echo\s*\necho\s*"==>\s*5\)\s*Send demo leads/\Q$replacement\E\n\necho\necho "==> 5) Send demo leads to webhook"/m
  or die "FAIL: could not find the Step 3..5 block to replace (script format changed)\n";
' scripts/client_experience_a2z.sh

chmod +x scripts/client_experience_a2z.sh

echo "==> bash -n (syntax check)"
bash -n scripts/client_experience_a2z.sh

echo "OK ✅ Patched A2Z script (syntax fixed, Node-only)."
echo "Backup: $BAK"
