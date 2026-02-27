#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"
SSOT="$ROOT/governance/ssot.md"
MANIFEST="$ROOT/governance/manifest.json"

[ -f "$MANIFEST" ] || { echo "missing $MANIFEST"; exit 1; }

MASTER="$(node -e "const fs=require('fs');const crypto=require('crypto');const t=fs.readFileSync('$MANIFEST','utf8');console.log(crypto.createHash('sha256').update(t,'utf8').digest('hex'))")"

perl -0777 -pe "s/MASTER_HASH:\s*([a-f0-9]{64}|__TBD__)/MASTER_HASH: $MASTER/i" -i "$SSOT"

echo "OK: set MASTER_HASH to $MASTER"
