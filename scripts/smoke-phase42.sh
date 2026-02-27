#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

need(){ [ -s "$1" ] || { echo "FAIL missing/empty: $1"; exit 1; }; }

need docs/SSOT_LOCK.md
need docs/PRODUCT_BOUNDARIES.md
need docs/SSOT_CHANGES.md
need docs/README.md

echo "✅ Phase42 smoke OK (SSOT files present)"
