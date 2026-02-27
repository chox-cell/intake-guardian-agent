#!/usr/bin/env bash
set -euo pipefail
echo "==> Phase53 smoke"
./scripts/probe-phase52.sh
./scripts/e2e-phase48.sh
echo "✅ Phase53 smoke OK"
