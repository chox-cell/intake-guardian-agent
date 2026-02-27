#!/usr/bin/env bash
set -euo pipefail

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK/scripts"

cp -v scripts/client_experience_a2z.sh "$BAK/scripts/client_experience_a2z.sh.bak"

# 1) Replace rg -n ... -o with rg -o (no line numbers)
# 2) Add a safety sanitize to strip any accidental leading "123:" just in case
perl -0777 -pi -e '
s/rg -n \x27http:\/\/127\\\.0\\\.0\\\.1:7090\/api\/auth\/verify\\\?token=\[A-Za-z0-9_-]\+\x27/rg -o \x27http:\/\/127\\\.0\\\.0\\\.1:7090\/api\/auth\/verify\\\?token=\[A-Za-z0-9_-]\+\x27/g;

s/rg -n \x27\/api\/auth\/verify\\\?token=\[A-Za-z0-9_-]\+\x27/rg -o \x27\/api\/auth\/verify\\\?token=\[A-Za-z0-9_-]\+\x27/g;

# after VERIFY_URL is set, ensure we strip leading "123:" if present
if ($_ !~ /VERIFY_URL="\$\{VERIFY_URL#\$\{VERIFY_URL%%\:\*\}\:\}"/s) {
  s/(echo "OK: verify URL extracted \(hidden\)".*?\n)/$1\n# sanitize any accidental \"NNN:\" prefix\nVERIFY_URL=\"\$(echo \"\$VERIFY_URL\" | sed -E \x27s\/^[0-9]+:\\s*\/\/\x27)\"\n/s;
}
' scripts/client_experience_a2z.sh

chmod +x scripts/client_experience_a2z.sh

echo "==> bash -n (syntax check)"
bash -n scripts/client_experience_a2z.sh

echo "OK ✅ Fixed A2Z verify URL extraction (no line-number prefix)."
echo "Backup: $BAK"
